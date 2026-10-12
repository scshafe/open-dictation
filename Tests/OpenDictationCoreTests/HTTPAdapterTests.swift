import XCTest
@testable import OpenDictationCore
import OpenDictationTestSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - HTTP adapter tests (URLProtocol stub lives in OpenDictationTestSupport)

final class HTTPAdapterTests: XCTestCase {
    private var tempDir: URL!
    private var audioURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        audioURL = tempDir.appendingPathComponent("rec.wav")
        try! WAVFile.writePCM16Mono(
            to: audioURL,
            samples: WAVFile.sineSamples(sampleRate: 16000, seconds: 0.1),
            sampleRate: 16000
        )
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequest = nil
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func config() -> ProviderConfig {
        ProviderConfig(
            endpointURL: URL(string: "http://127.0.0.1:9/v1/audio/transcriptions")!,
            model: "tiny",
            bearerToken: "tok"
        )
    }

    private func adapter() -> HTTPTranscriptionAdapter {
        HTTPTranscriptionAdapter(makeSession: { config in
            let sessionConfig = URLSessionConfiguration.ephemeral
            sessionConfig.protocolClasses = [StubURLProtocol.self]
            sessionConfig.timeoutIntervalForRequest = config.requestTimeout
            sessionConfig.timeoutIntervalForResource = config.resourceTimeout
            return URLSession(configuration: sessionConfig, delegate: RedirectGuardDelegate(), delegateQueue: nil)
        })
    }

    func testSuccessReturnsTextAndSendsContract() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
            let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
            XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
            return StubURLProtocol.StubResponse(statusCode: 200, body: Data("{\"text\":\"hello\"}".utf8))
        }
        let result = try await adapter().transcribe(audioURL: audioURL, config: config())
        XCTAssertEqual(result.text, "hello")
    }

    func testOmitsAuthHeaderWithoutToken() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return StubURLProtocol.StubResponse(statusCode: 200, body: Data("{\"text\":\"hi\"}".utf8))
        }
        var config = config()
        config.bearerToken = nil
        _ = try await adapter().transcribe(audioURL: audioURL, config: config)
    }

    func testClassifiesErrors() async {
        let cases: [(Int, Data, ProviderError)] = [
            (401, Data("{\"error\":\"bad\"}".utf8), .auth("{\"error\":\"bad\"}")),
            (429, Data(), .rateLimited),
            (500, Data("boom".utf8), .server("boom")),
            (200, Data("not json".utf8), .malformedResponse("invalid JSON")),
            (200, Data("{\"text\":\"  \"}".utf8), .emptyTranscript),
            (200, Data("{\"nope\":true}".utf8), .malformedResponse("missing 'text' field"))
        ]
        for (status, body, expected) in cases {
            StubURLProtocol.handler = { _ in StubURLProtocol.StubResponse(statusCode: status, body: body) }
            do {
                _ = try await adapter().transcribe(audioURL: audioURL, config: config())
                XCTFail("expected throw for status \(status)")
            } catch let error as ProviderError {
                XCTAssertEqual(error, expected, "status \(status)")
            } catch {
                XCTFail("wrong error type: \(error)")
            }
        }
    }

    func testServerErrorBodyIsNeverReturnedAsTranscript() async {
        StubURLProtocol.handler = { _ in
            StubURLProtocol.StubResponse(statusCode: 500, body: Data("{\"text\":\"EVIL AS TEXT\"}".utf8))
        }
        do {
            _ = try await adapter().transcribe(audioURL: audioURL, config: config())
            XCTFail("expected throw")
        } catch let error as ProviderError {
            if case .server = error { /* correct */ }
            else { XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("wrong error type")
        }
    }

    func testTimeoutAndTransportMapping() async {
        StubURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do {
            _ = try await adapter().transcribe(audioURL: audioURL, config: config())
            XCTFail("expected timeout")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .timeout)
        } catch { XCTFail("wrong error type") }

        StubURLProtocol.handler = { _ in throw URLError(.cannotFindHost) }
        do {
            _ = try await adapter().transcribe(audioURL: audioURL, config: config())
            XCTFail("expected transport error")
        } catch let error as ProviderError {
            if case .transport = error { /* correct */ }
            else { XCTFail("wrong error: \(error)") }
        } catch { XCTFail("wrong error type") }
    }

    func testUploadSizeGuard() async {
        StubURLProtocol.handler = { _ in
            XCTFail("request must not be sent when over the size limit")
            return StubURLProtocol.StubResponse(statusCode: 200, body: Data())
        }
        var config = config()
        config.maxUploadBytes = 10 // fixture is larger
        do {
            _ = try await adapter().transcribe(audioURL: audioURL, config: config)
            XCTFail("expected uploadTooLarge")
        } catch let error as ProviderError {
            if case .uploadTooLarge = error { /* correct */ }
            else { XCTFail("wrong error: \(error)") }
        } catch { XCTFail("wrong error type") }
    }

    func testRedirectGuardRefusesCrossOrigin() {
        let delegate = RedirectGuardDelegate()
        let session = URLSession(configuration: .ephemeral)
        let originalURL = URL(string: "https://asr.example.com/v1/audio/transcriptions")!
        let task = session.dataTask(with: originalURL)

        let sameOrigin = URLRequest(url: URL(string: "https://asr.example.com/other")!)
        let crossOrigin = URLRequest(url: URL(string: "https://evil.example.net/steal")!)
        let response = HTTPURLResponse(url: originalURL, statusCode: 302, httpVersion: nil, headerFields: nil)!

        let sameExp = expectation(description: "same origin followed")
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: sameOrigin) { request in
            XCTAssertNotNil(request)
            sameExp.fulfill()
        }
        let crossExp = expectation(description: "cross origin refused")
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: crossOrigin) { request in
            XCTAssertNil(request)
            crossExp.fulfill()
        }
        wait(for: [sameExp, crossExp], timeout: 2)
    }

    func testRefusedRedirectSurfacesAsRedirectBlocked() async {
        // A refused redirect makes URLSession deliver the 3xx itself.
        StubURLProtocol.handler = { _ in StubURLProtocol.StubResponse(statusCode: 302, body: Data()) }
        do {
            _ = try await adapter().transcribe(audioURL: audioURL, config: config())
            XCTFail("expected redirectBlocked")
        } catch let error as ProviderError {
            if case .redirectBlocked = error { /* correct */ }
            else { XCTFail("wrong error: \(error)") }
        } catch { XCTFail("wrong error type") }
    }

    func testSameOriginIncludesEffectivePort() {
        let base = URL(string: "http://127.0.0.1:8080/v1")!
        XCTAssertTrue(RedirectGuardDelegate.isSameOrigin(base, URL(string: "http://127.0.0.1:8080/other")))
        XCTAssertFalse(RedirectGuardDelegate.isSameOrigin(base, URL(string: "http://127.0.0.1:9999/other")))
        XCTAssertTrue(RedirectGuardDelegate.isSameOrigin(URL(string: "https://ASR.example.com/a"), URL(string: "https://asr.example.com:443/b")))
        XCTAssertFalse(RedirectGuardDelegate.isSameOrigin(URL(string: "https://asr.example.com/a"), URL(string: "http://asr.example.com/a")))
        XCTAssertFalse(RedirectGuardDelegate.isSameOrigin(base, nil))
    }
}
