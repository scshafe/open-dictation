import Foundation
#if canImport(AVFoundation)
import AVFoundation

// MARK: - Deterministic tap-buffer conversion (pure memory operation)
//
// Capture files are written with buffers that EXACTLY match the file format
// (interleaved Float32), because write-path conversion in AVAudioFile is
// unreliable on this OS (silent >4096-frame truncation; int16 aborts). This
// helper converts any tap buffer to that format on the writer queue — never on
// the realtime tap — and is fully unit-testable without a microphone.

public enum AudioBufferConvert {
    /// Convert `buffer` to interleaved Float32 `target` (same sample rate and
    /// channel count). Returns nil for exotic formats the recorder refuses to
    /// guess about — the caller must fail loudly, never write garbage.
    public static func toInterleavedFloat32(
        _ buffer: AVAudioPCMBuffer,
        target: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard target.commonFormat == .pcmFormatFloat32,
              target.isInterleaved,
              target.sampleRate == buffer.format.sampleRate,
              target.channelCount == buffer.format.channelCount,
              target.channelCount > 0
        else { return nil }
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: buffer.frameLength) else {
            return nil
        }
        out.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0 else { return out }

        var abl = out.audioBufferList.pointee
        guard abl.mNumberBuffers == 1,
              let dstRaw = abl.mBuffers.mData else { return nil }
        let dst = dstRaw.assumingMemoryBound(to: Float.self)

        if !buffer.format.isInterleaved {
            if let src = buffer.floatChannelData {
                for ch in 0..<channels {
                    let col = src[ch]
                    for i in 0..<frames { dst[i * channels + ch] = col[i] }
                }
                return out
            }
            if let src = buffer.int16ChannelData {
                for ch in 0..<channels {
                    let col = src[ch]
                    for i in 0..<frames { dst[i * channels + ch] = Float(col[i]) / Float(Int16.max) }
                }
                return out
            }
            if let src = buffer.int32ChannelData {
                for ch in 0..<channels {
                    let col = src[ch]
                    for i in 0..<frames { dst[i * channels + ch] = Float(col[i]) / Float(Int32.max) }
                }
                return out
            }
            return nil
        }

        // Interleaved source: stride through the single data buffer.
        var srcABL = buffer.audioBufferList.pointee
        guard srcABL.mNumberBuffers == 1,
              let srcRaw = srcABL.mBuffers.mData else { return nil }
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            let src = srcRaw.assumingMemoryBound(to: Float.self)
            for i in 0..<(frames * channels) { dst[i] = src[i] }
            return out
        case .pcmFormatInt16:
            let src = srcRaw.assumingMemoryBound(to: Int16.self)
            for i in 0..<(frames * channels) { dst[i] = Float(src[i]) / Float(Int16.max) }
            return out
        case .pcmFormatInt32:
            let src = srcRaw.assumingMemoryBound(to: Int32.self)
            for i in 0..<(frames * channels) { dst[i] = Float(src[i]) / Float(Int32.max) }
            return out
        default:
            return nil
        }
    }
}
#endif
