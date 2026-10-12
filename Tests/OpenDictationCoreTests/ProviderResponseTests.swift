import XCTest
@testable import OpenDictationCore
import Foundation

final class ProviderResponseTests: XCTestCase {
    func testParsesTextFieldVerbatim() throws {
        let result = try TranscriptResponseParser.parse(data: Data("{\"text\":\"Hello,  world!\"}".utf8))
        XCTAssertEqual(result.text, "Hello,  world!")
    }

    func testMissingTextIsMalformed() {
        XCTAssertThrowsError(try TranscriptResponseParser.parse(data: Data("{\"nope\":1}".utf8))) { error in
            XCTAssertEqual(error as? ProviderError, .malformedResponse("missing 'text' field"))
        }
    }

    func testInvalidJSONIsMalformed() {
        XCTAssertThrowsError(try TranscriptResponseParser.parse(data: Data("not json".utf8))) { error in
            XCTAssertEqual(error as? ProviderError, .malformedResponse("invalid JSON"))
        }
    }

    func testEmptyTextIsEmptyNotMalformed() {
        XCTAssertThrowsError(try TranscriptResponseParser.parse(data: Data("{\"text\":\"   \"}".utf8))) { error in
            XCTAssertEqual(error as? ProviderError, .emptyTranscript)
        }
    }

    func testStatusClassification() {
        XCTAssertEqual(HTTPStatusClassifier.error(statusCode: 401, bodyPrefix: nil), .auth(""))
        XCTAssertEqual(HTTPStatusClassifier.error(statusCode: 403, bodyPrefix: nil), .auth(""))
        XCTAssertEqual(HTTPStatusClassifier.error(statusCode: 429, bodyPrefix: nil), .rateLimited)
        XCTAssertEqual(HTTPStatusClassifier.error(statusCode: 413, bodyPrefix: nil), .unsupportedUpload("HTTP 413"))
        XCTAssertEqual(HTTPStatusClassifier.error(statusCode: 500, bodyPrefix: nil), .server("HTTP 500"))
        XCTAssertEqual(HTTPStatusClassifier.error(statusCode: 503, bodyPrefix: "busy"), .server("busy"))
        XCTAssertEqual(HTTPStatusClassifier.error(statusCode: 418, bodyPrefix: nil), .httpStatus(418, ""))
        for code in [301, 302, 307, 308] {
            if case .redirectBlocked = HTTPStatusClassifier.error(statusCode: code, bodyPrefix: nil) { /* correct */ }
            else { XCTFail("expected redirectBlocked for \(code)") }
        }
    }

    func testRetryabilityKeepsAudioOnlyForTransientFailures() {
        XCTAssertTrue(ProviderError.transport("x").keepsAudioForRetry)
        XCTAssertTrue(ProviderError.timeout.keepsAudioForRetry)
        XCTAssertTrue(ProviderError.rateLimited.keepsAudioForRetry)
        XCTAssertTrue(ProviderError.server("x").keepsAudioForRetry)
        XCTAssertFalse(ProviderError.auth("x").keepsAudioForRetry)
        XCTAssertFalse(ProviderError.unsupportedUpload("x").keepsAudioForRetry)
        XCTAssertFalse(ProviderError.malformedResponse("x").keepsAudioForRetry)
        XCTAssertFalse(ProviderError.emptyTranscript.keepsAudioForRetry)
        XCTAssertFalse(ProviderError.redirectBlocked("x").keepsAudioForRetry)
        XCTAssertFalse(ProviderError.uploadTooLarge(1).keepsAudioForRetry)
        XCTAssertFalse(ProviderError.cancelled.keepsAudioForRetry)
    }

    func testUserMessagesContainNoSecrets() {
        let messages = [
            ProviderError.auth("Bearer abc").userMessage,
            ProviderError.server("stack trace").userMessage,
            ProviderError.transport("host").userMessage
        ]
        for message in messages {
            XCTAssertFalse(message.contains("abc"))
        }
    }
}
