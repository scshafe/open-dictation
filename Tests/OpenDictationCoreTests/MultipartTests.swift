import XCTest
@testable import OpenDictationCore
import Foundation

final class MultipartTests: XCTestCase {
    private func config(model: String? = "test-model", language: String? = nil, token: String? = "secret") -> ProviderConfig {
        ProviderConfig(
            endpointURL: URL(string: "http://127.0.0.1:8080/v1/audio/transcriptions")!,
            model: model,
            language: language,
            bearerToken: token
        )
    }

    func testBodyContainsFilePartWithAudioMIME() {
        let audio = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x01]) // "RIFF.."
        let (body, contentType) = MultipartRequestBuilder.buildBody(
            audioData: audio, config: config(), boundary: "BOUNDARY"
        )
        XCTAssertTrue(contentType.contains("multipart/form-data; boundary=BOUNDARY"))
        let text = String(data: body, encoding: .utf8)!
        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\""))
        XCTAssertTrue(text.contains("Content-Type: audio/wav"))
        XCTAssertTrue(body.suffix("BOUNDARY--\r\n".utf8.count).elementsEqual(Data("--BOUNDARY--\r\n".utf8)))
        // Audio bytes embedded verbatim.
        XCTAssertTrue(body.range(of: audio) != nil)
    }

    func testModelAndLanguageSentOnlyWhenPopulated() {
        let withBoth = MultipartRequestBuilder.buildBody(
            audioData: Data([1]), config: config(model: "m", language: "en"), boundary: "B"
        )
        let textBoth = String(data: withBoth.body, encoding: .utf8)!
        XCTAssertTrue(textBoth.contains("name=\"model\""))
        XCTAssertTrue(textBoth.contains("\r\n\r\nm\r\n"))
        XCTAssertTrue(textBoth.contains("name=\"language\""))

        let withNeither = MultipartRequestBuilder.buildBody(
            audioData: Data([1]), config: config(model: nil, language: nil), boundary: "B"
        )
        let textNeither = String(data: withNeither.body, encoding: .utf8)!
        XCTAssertFalse(textNeither.contains("name=\"model\""))
        XCTAssertFalse(textNeither.contains("name=\"language\""))
    }

    func testAuthHeaderOnlyWhenTokenConfigured() {
        let withToken = MultipartRequestBuilder.buildRequest(audioData: Data([1]), config: config(token: "abc"))
        XCTAssertEqual(withToken.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
        XCTAssertEqual(withToken.httpMethod, "POST")
        // Exact configured URL, no appended paths.
        XCTAssertEqual(withToken.url?.absoluteString, "http://127.0.0.1:8080/v1/audio/transcriptions")

        let withoutToken = MultipartRequestBuilder.buildRequest(audioData: Data([1]), config: config(token: nil))
        XCTAssertNil(withoutToken.value(forHTTPHeaderField: "Authorization"))
    }

    func testConfigRedactionNeverIncludesToken() {
        let c = config(token: "super-secret-token")
        XCTAssertFalse(c.redactedDescription.contains("super-secret-token"))
        XCTAssertTrue(c.redactedDescription.contains("bearer:set"))
    }
}
