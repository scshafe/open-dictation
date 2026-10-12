import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

// MARK: - WAV format knowledge (pure, testable)

public enum WAVError: Error, Equatable {
    case invalidHeader(String)
    case unsupportedFormat(String)
    case io(String)
}

public struct WAVInfo: Equatable {
    public var sampleRate: Int
    public var channels: Int
    public var bitsPerSample: Int
    public var frames: Int
    public var durationSeconds: Double
    public var dataBytes: Int
}

public enum WAVFile {
    /// Default upload format: mono 16-bit PCM at 16 kHz.
    public static let targetSampleRate = 16_000
    public static let targetChannels = 1
    public static let targetBitsPerSample = 16

    /// Write mono 16-bit PCM samples as a valid WAV file. Pure writer used by
    /// tests and by the "test connection" tone generator.
    public static func writePCM16Mono(to url: URL, samples: [Int16], sampleRate: Int) throws {
        var data = Data()
        func u32(_ v: UInt32) {
            var le = v.littleEndian
            data.append(Data(bytes: &le, count: 4))
        }
        func u16(_ v: UInt16) {
            var le = v.littleEndian
            data.append(Data(bytes: &le, count: 2))
        }
        let dataBytes = samples.count * 2
        data.append(Data("RIFF".utf8)); u32(UInt32(36 + dataBytes))
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append(Data("data".utf8)); u32(UInt32(dataBytes))
        samples.withUnsafeBytes { raw in
            // Int16 little-endian on all supported Macs; write explicit LE.
            var le = Data(capacity: raw.count)
            for i in 0..<samples.count {
                var s = samples[i].littleEndian
                le.append(Data(bytes: &s, count: 2))
            }
            data.append(le)
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw WAVError.io(error.localizedDescription)
        }
    }

    /// Parse and validate a WAV header; returns format facts used by tests and
    /// by the converter's post-condition check.
    public static func readInfo(from url: URL) throws -> WAVInfo {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw WAVError.io(error.localizedDescription)
        }
        guard data.count >= 44 else { throw WAVError.invalidHeader("file too short") }
        func tag(_ offset: Int) -> String { String(data: data[offset..<offset + 4], encoding: .ascii) ?? "" }
        func u32(_ offset: Int) -> UInt32 {
            data[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        }
        func u16(_ offset: Int) -> UInt16 {
            data[offset..<offset + 2].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian }
        }
        guard tag(0) == "RIFF", tag(8) == "WAVE", tag(12) == "fmt " else {
            throw WAVError.invalidHeader("missing RIFF/WAVE/fmt")
        }
        let audioFormat = u16(20)
        guard audioFormat == 1 else { throw WAVError.unsupportedFormat("only PCM supported, got \(audioFormat)") }
        let channels = Int(u16(22))
        let sampleRate = Int(u32(24))
        let bits = Int(u16(34))
        // Locate the data chunk (fmt chunk may carry extra bytes).
        var cursor = 12
        var dataBytes = 0
        while cursor + 8 <= data.count {
            let id = tag(cursor)
            let size = Int(u32(cursor + 4))
            if id == "data" { dataBytes = size; break }
            cursor += 8 + size
            if cursor % 2 == 1 { cursor += 1 }
        }
        guard dataBytes > 0 else { throw WAVError.invalidHeader("missing data chunk") }
        let bytesPerFrame = channels * bits / 8
        guard bytesPerFrame > 0 else { throw WAVError.invalidHeader("bad format") }
        let frames = dataBytes / bytesPerFrame
        return WAVInfo(
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bits,
            frames: frames,
            durationSeconds: sampleRate > 0 ? Double(frames) / Double(sampleRate) : 0,
            dataBytes: dataBytes
        )
    }

    /// Generate a deterministic sine fixture (1 kHz default) for tests and demos.
    public static func sineSamples(sampleRate: Int, seconds: Double, frequency: Double = 1000, amplitude: Double = 0.5) -> [Int16] {
        let count = Int(Double(sampleRate) * seconds)
        return (0..<count).map { i in
            let t = Double(i) / Double(sampleRate)
            return Int16(sin(2 * .pi * frequency * t) * amplitude * Double(Int16.max))
        }
    }
}

#if canImport(AVFoundation)
// MARK: - Offline conversion (never on the realtime tap)
//
// Design note (verified empirically on macOS 26, Sept 2026): AVAudioFile.write
// performs on-the-fly conversion when the buffer format differs from the file
// format, and that path is unreliable here — an int16→float32 write aborts the
// process in ExtAudioFile, and a >4096-frame write through a converter
// silently truncates to 4096 frames. So ALL conversion happens in memory via
// AVAudioConverter (pull pattern), and the WAV file is written by the pure
// WAVFile writer. File writes never convert; buffers always match the file.

public protocol AudioConverting {
    /// Convert any decodable capture file to the upload WAV format.
    /// Runs off the realtime callback; may be slow for long recordings.
    func convertToUploadWAV(source: URL) throws -> URL
    func makeTempURL(suffix: String) -> URL
}

public final class AudioFileConverter: AudioConverting {
    public let targetSampleRate: Int

    public init(targetSampleRate: Int = WAVFile.targetSampleRate) {
        self.targetSampleRate = targetSampleRate
    }

    public func makeTempURL(suffix: String) -> URL {
        TempAudioStore.shared.newURL(suffix: suffix)
    }

    public func convertToUploadWAV(source: URL) throws -> URL {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source)
        } catch {
            throw WAVError.io("cannot read capture: \(error.localizedDescription)")
        }
        guard input.length > 0 else { throw WAVError.invalidHeader("capture has no frames") }
        let inputFormat = input.processingFormat
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw WAVError.unsupportedFormat("unreadable capture format")
        }
        // Defense in depth: the recorder enforces a minutes-scale limit, but a
        // corrupt header claiming absurd length must not allocate unboundedly.
        let inputSeconds = Double(input.length) / inputFormat.sampleRate
        guard inputSeconds <= 3600 else {
            throw WAVError.unsupportedFormat("capture too long (\(Int(inputSeconds))s)")
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(targetSampleRate),
            channels: AVAudioChannelCount(WAVFile.targetChannels),
            interleaved: true
        ) else {
            throw WAVError.unsupportedFormat("cannot build output format")
        }
        // AVAudioConverter performs a real resample; the rate is never relabeled.
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw WAVError.unsupportedFormat("cannot convert \(inputFormat) to \(outputFormat)")
        }

        // Pull pattern: the input block streams file chunks on demand (one in
        // flight — bounded), and convert() is called until endOfStream.
        var samples = [Int16]()
        samples.reserveCapacity(min(Int(inputSeconds * Double(targetSampleRate)) + 1024, 120_000_000))
        var reachedEOF = false
        var streamError: Error?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if reachedEOF || input.framePosition >= input.length {
                reachedEOF = true
                outStatus.pointee = .endOfStream
                return nil
            }
            guard let chunk = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 8192) else {
                streamError = WAVError.io("buffer alloc failed")
                outStatus.pointee = .endOfStream
                reachedEOF = true
                return nil
            }
            do {
                try input.read(into: chunk)
            } catch {
                streamError = WAVError.io("capture read failed: \(error.localizedDescription)")
                outStatus.pointee = .endOfStream
                reachedEOF = true
                return nil
            }
            if chunk.frameLength == 0 {
                reachedEOF = true
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            return chunk
        }

        var iterations = 0
        while true {
            iterations += 1
            guard iterations < 100_000 else {
                throw WAVError.unsupportedFormat("converter did not terminate")
            }
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 16384) else {
                throw WAVError.io("buffer alloc failed")
            }
            var converterNSError: NSError?
            let status = converter.convert(to: outBuffer, error: &converterNSError, withInputFrom: inputBlock)
            if let streamError { throw streamError }
            if let converterNSError {
                throw WAVError.unsupportedFormat("converter error: \(converterNSError.localizedDescription)")
            }
            if outBuffer.frameLength > 0 {
                guard let channels = outBuffer.int16ChannelData else {
                    throw WAVError.io("converter output unreadable")
                }
                samples.append(contentsOf: UnsafeBufferPointer(
                    start: channels[0], count: Int(outBuffer.frameLength)
                ))
            }
            if status == .endOfStream { break }
            if status == .error { throw WAVError.unsupportedFormat("converter error") }
        }
        guard !samples.isEmpty else {
            throw WAVError.invalidHeader("conversion produced no audio")
        }
        let destination = makeTempURL(suffix: "wav")
        try WAVFile.writePCM16Mono(to: destination, samples: samples, sampleRate: targetSampleRate)
        // Post-condition: the file on disk is really the documented format.
        let info = try WAVFile.readInfo(from: destination)
        guard info.sampleRate == targetSampleRate,
              info.channels == WAVFile.targetChannels,
              info.bitsPerSample == WAVFile.targetBitsPerSample else {
            throw WAVError.invalidHeader("conversion produced unexpected format: \(info)")
        }
        return destination
    }
}
#endif
