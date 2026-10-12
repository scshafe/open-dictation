import Foundation
import OpenDictationCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Shared fakes and stubs (no XCTest dependency)
//
// Used by Tests/OpenDictationCoreTests (XCTest, Xcode hosts) and by
// Sources/OpenDictationSelfTest (dependency-free runner, CLT-only hosts).

public final class FakeRecorder: AudioRecordingService {
    public var onLevel: ((Float) -> Void)?
    public var onDuration: ((TimeInterval) -> Void)?
    public var onOverload: (() -> Void)?
    public var onDeviceChange: ((String) -> Void)?
    public var startError: Error?
    public var started = false
    public var startCount = 0
    public var cancelled = false
    public let captureFile: URL

    public init(captureFile: URL) { self.captureFile = captureFile }

    public func start() throws {
        startCount += 1
        if started { throw RecorderError.alreadyRecording }
        if let startError { throw startError }
        started = true
    }

    public func stop() throws -> URL {
        guard started else { throw RecorderError.notRecording }
        started = false
        return captureFile
    }

    public func cancel() {
        started = false
        cancelled = true
    }
}

public struct FakeConverter: AudioConverting {
    public let outputDir: URL
    public init(outputDir: URL) { self.outputDir = outputDir }
    public func makeTempURL(suffix: String) -> URL {
        outputDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
    }
    public func convertToUploadWAV(source: URL) throws -> URL {
        let url = makeTempURL(suffix: "wav")
        try WAVFile.writePCM16Mono(
            to: url,
            samples: WAVFile.sineSamples(sampleRate: 16000, seconds: 0.05),
            sampleRate: 16000
        )
        return url
    }
}

public final class FakeInserter: TextInserter {
    public var directOutcome: InsertionOutcome = .inserted(method: "accessibility")
    public var pasteOutcome: InsertionOutcome = .uncertain(reason: "paste sent")
    public var directCalls = 0
    public var pasteCalls = 0
    public var lastText: String?

    public init() {}

    public func insertDirect(text: String, snapshot: DestinationSnapshot) async -> InsertionOutcome {
        directCalls += 1
        lastText = text
        return directOutcome
    }

    public func insertViaPaste(text: String, snapshot: DestinationSnapshot) async -> InsertionOutcome {
        pasteCalls += 1
        lastText = text
        return pasteOutcome
    }
}

public final class FakeDestinations: DestinationService {
    public var captured: DestinationSnapshot?
    public var current: DestinationSnapshot?
    public var accessibilityTrusted = true
    public init() {}
    public func captureSnapshot() -> DestinationSnapshot? { captured }
    public func currentSnapshot() -> DestinationSnapshot? { current }
}

/// Mutable reference cell for closures that must observe test-driven state
/// changes (e.g. microphone permission flipping after the system prompt).
public final class Box<Value> {
    public var value: Value
    public init(_ value: Value) { self.value = value }
}

@MainActor
public final class StubConfigSource: SessionConfigSource {
    public var settings: AppSettings
    public var token: String? = "test-token"
    public init(settings: AppSettings = AppSettings()) { self.settings = settings }
    public func currentSettings() -> AppSettings { settings }
    public func currentToken() -> String? { token }
}

// MARK: - Deterministic URLProtocol stub (no network)

public final class StubURLProtocol: URLProtocol {
    public struct StubResponse {
        public var statusCode: Int
        public var body: Data
        public init(statusCode: Int, body: Data) {
            self.statusCode = statusCode
            self.body = body
        }
    }
    public static var handler: ((URLRequest) throws -> StubResponse)?
    public static var lastRequest: URLRequest?

    override public class func canInit(with request: URLRequest) -> Bool { true }
    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        Self.lastRequest = request
        do {
            guard let stub = try Self.handler?(request) else {
                throw URLError(.badServerResponse)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override public func stopLoading() {}
}
