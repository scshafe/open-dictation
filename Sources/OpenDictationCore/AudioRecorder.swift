import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

// MARK: - Microphone permission (status + user-initiated request)

public enum MicStatus: Equatable, Sendable {
    case authorized
    case denied
    case notDetermined
}

public enum MicrophonePermission {
#if canImport(AVFoundation)
    public static func status() -> MicStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    /// Shows the system prompt. Call only from a user-initiated flow
    /// (Record button / dictation shortcut).
    public static func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
#else
    public static func status() -> MicStatus { .denied }
    public static func request() async -> Bool { false }
#endif
}

#if canImport(AVFoundation)
// MARK: - Recorder: AVAudioEngine capture with bounded off-callback writing
//
// The realtime tap NEVER does blocking file I/O: it copies the buffer into a
// bounded queue (max 256 buffers) drained by a serial writer queue, and
// computes only a cheap RMS level inline. On overflow the recorder reports
// overload (via onOverload) and drops buffers instead of growing memory.

private final class CaptureWriter {
    private let file: AVAudioFile
    private let fileFormat: AVAudioFormat // interleaved Float32; buffers converted to match
    private let queue = DispatchQueue(label: "com.example.opendictation.capturewriter")
    private let lock = NSLock()
    private var pending: [AVAudioPCMBuffer] = []
    private let maxPending = 256
    private var framesWritten: AVAudioFramePosition = 0
    private var writeError: Error?
    private var overloadReported = false
    private let sampleRate: Double

    var onFramesWritten: ((TimeInterval) -> Void)?
    var onOverload: (() -> Void)?

    init(file: AVAudioFile, fileFormat: AVAudioFormat) {
        self.file = file
        self.fileFormat = fileFormat
        self.sampleRate = fileFormat.sampleRate
    }

    /// Called on the realtime tap. Must not block.
    func enqueue(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if pending.count >= maxPending {
            let shouldReport = !overloadReported
            overloadReported = true
            lock.unlock()
            if shouldReport { onOverload?() }
            return // drop: bounded by design, overload reported
        }
        pending.append(buffer)
        lock.unlock()
        queue.async { [weak self] in self?.drain() }
    }

    private func drain() {
        while true {
            lock.lock()
            guard !pending.isEmpty else { lock.unlock(); return }
            let buffer = pending.removeFirst()
            lock.unlock()
            // Convert to the exact file format first: file writes never convert.
            guard let matched = AudioBufferConvert.toInterleavedFloat32(buffer, target: fileFormat) else {
                fail(RecorderError.writeFailed("unsupported input format \(buffer.format)"))
                return
            }
            do {
                try file.write(from: matched)
            } catch {
                fail(error)
                return
            }
            framesWritten += AVAudioFramePosition(matched.frameLength)
            let duration = sampleRate > 0 ? TimeInterval(framesWritten) / sampleRate : 0
            onFramesWritten?(duration)
        }
    }

    private func fail(_ error: Error) {
        lock.lock()
        if writeError == nil { writeError = error }
        lock.unlock()
    }

    /// Drain remaining buffers synchronously. Call off the writer queue.
    func finish() throws -> TimeInterval {
        queue.sync { drain() }
        lock.lock()
        defer { lock.unlock() }
        if let writeError { throw writeError }
        return sampleRate > 0 ? TimeInterval(framesWritten) / sampleRate : 0
    }
}

public final class AudioRecorder: AudioRecordingService {
    public var onLevel: ((Float) -> Void)?
    public var onDuration: ((TimeInterval) -> Void)?
    public var onOverload: (() -> Void)?
    public var onDeviceChange: ((String) -> Void)?

    private let tempStore: TempAudioStore
    private var engine: AVAudioEngine?
    private var writer: CaptureWriter?
    private var captureURL: URL?
    private var tapInstalled = false
    private var configObserver: NSObjectProtocol?

    public init(tempStore: TempAudioStore = .shared) {
        self.tempStore = tempStore
    }

    public func start() throws {
        guard MicrophonePermission.status() == .authorized else {
            throw RecorderError.permissionDenied
        }
        guard !tapInstalled else { throw RecorderError.alreadyRecording }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }
        // Capture file: interleaved Float32 at the device rate/channels.
        // Tap buffers are converted to EXACTLY this format before writing.
        guard let fileFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: format.channelCount,
            interleaved: true
        ) else {
            throw RecorderError.noInputDevice
        }
        let settings = Self.captureSettings(sampleRate: fileFormat.sampleRate, channels: fileFormat.channelCount)
        let url = tempStore.newURL(suffix: "caf")
        let file: AVAudioFile
        do {
            file = try Self.makeCaptureFile(url: url, settings: settings, fileFormat: fileFormat)
        } catch let error as RecorderError {
            tempStore.delete(url)
            throw error
        } catch {
            tempStore.delete(url)
            throw RecorderError.writeFailed(error.localizedDescription)
        }
        let writer = CaptureWriter(file: file, fileFormat: fileFormat)
        writer.onFramesWritten = { [weak self] duration in self?.onDuration?(duration) }
        writer.onOverload = { [weak self] in self?.onOverload?() }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self, weak writer] buffer, _ in
            guard let self, let writer else { return }
            self.onLevel?(Self.rmsLevel(of: buffer))
            if let copy = Self.copyBuffer(buffer) {
                writer.enqueue(copy)
            }
        }
        tapInstalled = true

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.onDeviceChange?("audio configuration changed")
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            if let observer = configObserver {
                NotificationCenter.default.removeObserver(observer)
                configObserver = nil
            }
            tempStore.delete(url)
            throw RecorderError.engineStartFailed(error.localizedDescription)
        }
        self.engine = engine
        self.writer = writer
        self.captureURL = url
    }

    public func stop() throws -> URL {
        guard tapInstalled, let engine, let url = captureURL else {
            throw RecorderError.notRecording
        }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
        engine.stop()
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        do {
            _ = try writer?.finish()
        } catch {
            cleanup(captureURL: url)
            throw RecorderError.writeFailed(error.localizedDescription)
        }
        self.engine = nil
        self.writer = nil
        self.captureURL = nil
        return url
    }

    public func cancel() {
        guard tapInstalled else { return }
        engine?.inputNode.removeTap(onBus: 0)
        tapInstalled = false
        engine?.stop()
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        let url = captureURL
        self.engine = nil
        self.writer = nil
        self.captureURL = nil
        tempStore.delete(url)
    }

    private func cleanup(captureURL url: URL?) {
        engine = nil
        writer = nil
        captureURL = nil
        tempStore.delete(url)
    }

    // MARK: - Capture file (format pinned; public for the regression test)

    /// Linear PCM Float32 interleaved at the device rate/channels.
    public static func captureSettings(sampleRate: Double, channels: AVAudioChannelCount) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    /// Open the capture file with its processing format pinned to `fileFormat`
    /// (interleaved Float32). The two-argument AVAudioFile initializer picks a
    /// DEINTERLEAVED processing format for multi-channel files; writing the
    /// recorder's interleaved buffers to that fails with -50 on every write
    /// (verified on macOS 26 with a 2-channel input). Pinning the format keeps
    /// writes conversion-free, and the post-condition turns any future mismatch
    /// into a loud start failure instead of a silently lost recording.
    public static func makeCaptureFile(url: URL, settings: [String: Any], fileFormat: AVAudioFormat) throws -> AVAudioFile {
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: true
        )
        guard file.processingFormat == fileFormat else {
            throw RecorderError.writeFailed(
                "capture file format mismatch: \(file.processingFormat) vs \(fileFormat)"
            )
        }
        return file
    }

    // MARK: - Tap helpers (must stay cheap)

    static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Double = 0
        var count = 0
        if let channels = buffer.floatChannelData {
            let ch0 = channels[0]
            for i in 0..<frames {
                let s = Double(ch0[i])
                sum += s * s
            }
            count = frames
        } else if let channels = buffer.int16ChannelData {
            let ch0 = channels[0]
            for i in 0..<frames {
                let s = Double(ch0[i]) / Double(Int16.max)
                sum += s * s
            }
            count = frames
        } else if let channels = buffer.int32ChannelData {
            let ch0 = channels[0]
            for i in 0..<frames {
                let s = Double(ch0[i]) / Double(Int32.max)
                sum += s * s
            }
            count = frames
        }
        guard count > 0 else { return 0 }
        let rms = sqrt(sum / Double(count))
        // Perceptual-ish mapping to 0...1 for the meter.
        return Float(min(1.0, rms * 3.0))
    }

    static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return copy }
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            let bytes = frames * MemoryLayout<Float>.size
            for ch in 0..<channels { memcpy(dst[ch], src[ch], bytes) }
        } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            let bytes = frames * MemoryLayout<Int16>.size
            for ch in 0..<channels { memcpy(dst[ch], src[ch], bytes) }
        } else if let src = buffer.int32ChannelData, let dst = copy.int32ChannelData {
            let bytes = frames * MemoryLayout<Int32>.size
            for ch in 0..<channels { memcpy(dst[ch], src[ch], bytes) }
        } else {
            return nil
        }
        return copy
    }
}
#endif
