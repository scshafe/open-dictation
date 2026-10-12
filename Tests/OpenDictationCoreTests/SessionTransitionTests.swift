import XCTest
@testable import OpenDictationCore

final class SessionTransitionTests: XCTestCase {
    func testHappyPathTransitions() {
        XCTAssertTrue(SessionTransition.isAllowed(from: .idle, to: .preparing))
        XCTAssertTrue(SessionTransition.isAllowed(from: .preparing, to: .recording))
        XCTAssertTrue(SessionTransition.isAllowed(from: .recording, to: .transcribing))
        XCTAssertTrue(SessionTransition.isAllowed(from: .transcribing, to: .resultReady))
        XCTAssertTrue(SessionTransition.isAllowed(from: .resultReady, to: .inserting))
        XCTAssertTrue(SessionTransition.isAllowed(from: .inserting, to: .completed))
    }

    func testCancelAndRetryTransitions() {
        XCTAssertTrue(SessionTransition.isAllowed(from: .recording, to: .canceled))
        XCTAssertTrue(SessionTransition.isAllowed(from: .transcribing, to: .canceled))
        XCTAssertTrue(SessionTransition.isAllowed(from: .transcribing, to: .failed))
        XCTAssertTrue(SessionTransition.isAllowed(from: .failed, to: .transcribing)) // explicit retry
        XCTAssertTrue(SessionTransition.isAllowed(from: .failed, to: .canceled))     // explicit discard
        XCTAssertTrue(SessionTransition.isAllowed(from: .resultReady, to: .completed))
        XCTAssertTrue(SessionTransition.isAllowed(from: .resultReady, to: .canceled))
        XCTAssertTrue(SessionTransition.isAllowed(from: .inserting, to: .resultReady)) // refused/failed insert keeps result
    }

    func testForbiddenTransitions() {
        // Canceled sessions never come back and never insert.
        XCTAssertFalse(SessionTransition.isAllowed(from: .canceled, to: .transcribing))
        XCTAssertFalse(SessionTransition.isAllowed(from: .canceled, to: .inserting))
        XCTAssertFalse(SessionTransition.isAllowed(from: .canceled, to: .resultReady))
        // Completed sessions are terminal.
        XCTAssertFalse(SessionTransition.isAllowed(from: .completed, to: .inserting))
        XCTAssertFalse(SessionTransition.isAllowed(from: .completed, to: .recording))
        // No skipping the pipeline.
        XCTAssertFalse(SessionTransition.isAllowed(from: .idle, to: .recording))
        XCTAssertFalse(SessionTransition.isAllowed(from: .recording, to: .resultReady))
        XCTAssertFalse(SessionTransition.isAllowed(from: .preparing, to: .inserting))
    }

    func testTerminalPhases() {
        XCTAssertTrue(SessionTransition.isTerminal(phase: .completed, retryable: false))
        XCTAssertTrue(SessionTransition.isTerminal(phase: .canceled, retryable: false))
        XCTAssertTrue(SessionTransition.isTerminal(phase: .failed, retryable: false))
        XCTAssertFalse(SessionTransition.isTerminal(phase: .failed, retryable: true))
        XCTAssertFalse(SessionTransition.isTerminal(phase: .resultReady, retryable: false))
    }
}
