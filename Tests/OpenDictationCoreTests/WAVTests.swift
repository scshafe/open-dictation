import XCTest
@testable import OpenDictationCore
import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

final class WAVTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testWriteAndReadRoundTrip() throws {
        let url = tempDir.appendingPathComponent("tone.wav")
        let samples = WAVFile.sineSamples(sampleRate: 16000, seconds: 0.25)
        try WAVFile.writePCM16Mono(to: url, samples: samples, sampleRate: 16000)
        let info = try WAVFile.readInfo(from: url)
        XCTAssertEqual(info.sampleRate, 16000)
        XCTAssertEqual(info.channels, 1)
        XCTAssertEqual(info.bitsPerSample, 16)
        XCTAssertEqual(info.frames, samples.count)
        XCTAssertEqual(info.durationSeconds, 0.25, accuracy: 0.001)
        XCTAssertEqual(info.dataBytes, samples.count * 2)
    }

    func testInvalidHeaderRejected() throws {
        let url = tempDir.appendingPathComponent("bad.wav")
        try Data("definitely not a wav file at all, just text".utf8).write(to: url)
        XCTAssertThrowsError(try WAVFile.readInfo(from: url))
    }

#if canImport(AVFoundation)
    func testConversionResamplesTo16kMono() throws {
        // 44.1 kHz mono fixture via the exact WAV writer (non-integer ratio
        // 44100 -> 16000 proves a real resample, not a relabel).
        let source = tempDir.appendingPathComponent("capture.wav")
        try WAVFile.writePCM16Mono(
            to: source,
            samples: WAVFile.sineSamples(sampleRate: 44100, seconds: 0.1),
            sampleRate: 44100
        )
        let converter = AudioFileConverter()
        let wavURL = try converter.convertToUploadWAV(source: source)
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let info = try WAVFile.readInfo(from: wavURL)
        XCTAssertEqual(info.sampleRate, 16000)
        XCTAssertEqual(info.channels, 1)
        XCTAssertEqual(info.bitsPerSample, 16)
        // Real resample: duration preserved (~0.1 s), frame count scaled to
        // ~1600. A mere relabel would report 4410 frames — excluded.
        XCTAssertEqual(info.durationSeconds, 0.1, accuracy: 0.01)
        XCTAssertLessThanOrEqual(abs(info.frames - 1600), 80)
    }

    func testConversionRejectsEmptyCapture() throws {
        let source = tempDir.appendingPathComponent("empty.wav")
        try WAVFile.writePCM16Mono(to: source, samples: [], sampleRate: 44100)
        XCTAssertThrowsError(try AudioFileConverter().convertToUploadWAV(source: source))
    }
#endif
}
