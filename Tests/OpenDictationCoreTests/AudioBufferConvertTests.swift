import XCTest
@testable import OpenDictationCore
import Foundation
#if canImport(AVFoundation)
import AVFoundation

/// Tap-buffer conversion without a microphone: synthetic buffers with known
/// patterns must convert to interleaved Float32 exactly.
final class AudioBufferConvertTests: XCTestCase {
    private func target(channels: UInt32, rate: Double = 48000) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: true)!
    }

    private func interleavedFloats(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let abl = buffer.audioBufferList.pointee
        XCTAssertEqual(abl.mNumberBuffers, 1)
        let ptr = abl.mBuffers.mData!.assumingMemoryBound(to: Float.self)
        let count = Int(buffer.frameLength) * Int(buffer.format.channelCount)
        return Array(UnsafeBufferPointer(start: ptr, count: count))
    }

    func testDeinterleavedFloatStereo() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        buffer.frameLength = 4
        for i in 0..<4 {
            buffer.floatChannelData![0][i] = Float(i)            // L: 0 1 2 3
            buffer.floatChannelData![1][i] = Float(10 + i)       // R: 10 11 12 13
        }
        let converted = AudioBufferConvert.toInterleavedFloat32(buffer, target: target(channels: 2))!
        XCTAssertEqual(interleavedFloats(converted), [0, 10, 1, 11, 2, 12, 3, 13])
    }

    func testDeinterleavedInt16MonoNormalizes() {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3)!
        buffer.frameLength = 3
        buffer.int16ChannelData![0][0] = Int16.max
        buffer.int16ChannelData![0][1] = 0
        buffer.int16ChannelData![0][2] = Int16.min + 1
        let converted = AudioBufferConvert.toInterleavedFloat32(buffer, target: target(channels: 1))!
        let values = interleavedFloats(converted)
        XCTAssertEqual(values[0], 1.0, accuracy: 0.0001)
        XCTAssertEqual(values[1], 0.0, accuracy: 0.0001)
        XCTAssertEqual(values[2], -1.0, accuracy: 0.0001)
    }

    func testInterleavedFloatPassthrough() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2)!
        buffer.frameLength = 2
        let abl = buffer.audioBufferList.pointee
        let ptr = abl.mBuffers.mData!.assumingMemoryBound(to: Float.self)
        ptr[0] = 0.5; ptr[1] = -0.5; ptr[2] = 0.25; ptr[3] = -0.25
        let converted = AudioBufferConvert.toInterleavedFloat32(buffer, target: target(channels: 2))!
        XCTAssertEqual(interleavedFloats(converted), [0.5, -0.5, 0.25, -0.25])
    }

    func testMismatchedTargetRefused() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2)!
        buffer.frameLength = 2
        // Wrong channel count and wrong rate must refuse, never guess.
        XCTAssertNil(AudioBufferConvert.toInterleavedFloat32(buffer, target: target(channels: 1)))
        XCTAssertNil(AudioBufferConvert.toInterleavedFloat32(buffer, target: target(channels: 2, rate: 44100)))
        let intTarget = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: true)!
        XCTAssertNil(AudioBufferConvert.toInterleavedFloat32(buffer, target: intTarget))
    }

    func testEmptyBufferConvertsToEmpty() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8)!
        buffer.frameLength = 0
        let converted = AudioBufferConvert.toInterleavedFloat32(buffer, target: target(channels: 1))!
        XCTAssertEqual(converted.frameLength, 0)
    }

    /// Regression: the capture file's processing format must equal the
    /// recorder's interleaved Float32 buffer format for ANY channel count, and
    /// writes above 4096 frames must be lossless. The two-argument AVAudioFile
    /// initializer broke this for stereo input (every write failed with -50).
    func testCaptureFileAcceptsInterleavedWritesForMonoAndStereo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for channels: AVAudioChannelCount in [1, 2] {
            let url = dir.appendingPathComponent("capture_\(channels).caf")
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: channels, interleaved: true)!
            var written = 0
            do { // scope: release the file before reopening
                let file = try AudioRecorder.makeCaptureFile(
                    url: url,
                    settings: AudioRecorder.captureSettings(sampleRate: 48000, channels: channels),
                    fileFormat: format
                )
                XCTAssertEqual(file.processingFormat, format)
                for frames in [4096, 4800, 8192] as [AVAudioFrameCount] {
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
                    buffer.frameLength = frames
                    try file.write(from: buffer)
                    written += Int(frames)
                }
            }
            let reopened = try AVAudioFile(forReading: url)
            XCTAssertEqual(Int(reopened.length), written, "channels=\(channels)")
        }
    }
}
#endif
