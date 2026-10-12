import XCTest
@testable import OpenDictationCore
import Foundation

final class PolicyTests: XCTestCase {
    private func snapshot(
        pid: Int32 = 100,
        bundle: String? = "com.example.editor",
        window: Int? = 7,
        role: String? = "AXTextArea",
        identifier: String? = "doc-1",
        selectedText: String? = "",
        location: Int? = 5,
        length: Int? = 0,
        fingerprint: Int? = 42,
        secure: Bool = false
    ) -> DestinationSnapshot {
        DestinationSnapshot(
            processID: pid,
            bundleIdentifier: bundle,
            windowNumber: window,
            focusedRole: role,
            focusedIdentifier: identifier,
            selectedText: selectedText,
            selectionLocation: location,
            selectionLength: length,
            valueFingerprint: fingerprint,
            isSecureField: secure
        )
    }

    func testUnchangedDestinationIsValid() {
        XCTAssertEqual(DestinationPolicy.validate(original: snapshot(), current: snapshot()), .valid)
    }

    func testChangedDestinationIsStale() {
        let original = snapshot()
        let variants: [DestinationSnapshot] = [
            snapshot(pid: 200),                       // different app
            snapshot(bundle: "com.other.app"),        // different app
            snapshot(window: 8),                      // different window
            snapshot(role: "AXTextField"),            // different field kind
            snapshot(identifier: "doc-2"),            // different field
            snapshot(location: 6),                    // caret moved
            snapshot(length: 3),                      // selection changed
            snapshot(selectedText: "hi"),             // selection changed
            snapshot(fingerprint: 43),                // contents changed
            snapshot(secure: true)                    // secure field
        ]
        for variant in variants {
            let check = DestinationPolicy.validate(original: original, current: variant)
            XCTAssertFalse(check.isValid, "expected stale for \(variant)")
            if case .stale = check { /* correct */ }
            else { XCTFail("expected .stale, got \(check)") }
        }
    }

    func testMissingTargetIsUnknown() {
        let check = DestinationPolicy.validate(original: snapshot(), current: nil)
        XCTAssertFalse(check.isValid)
        if case .unknown = check { /* correct */ }
        else { XCTFail("expected .unknown, got \(check)") }
    }

    func testFallbackOnlyAfterUnsupported() {
        XCTAssertTrue(InsertionOrchestrator.shouldAttemptFallback(after: .unsupported(reason: "x")))
        // Never paste after these: success needs nothing; refusal must not
        // guess; failure/uncertain must not risk duplication.
        XCTAssertFalse(InsertionOrchestrator.shouldAttemptFallback(after: .inserted(method: "accessibility")))
        XCTAssertFalse(InsertionOrchestrator.shouldAttemptFallback(after: .skippedStale(reason: "x")))
        XCTAssertFalse(InsertionOrchestrator.shouldAttemptFallback(after: .failed(reason: "x")))
        XCTAssertFalse(InsertionOrchestrator.shouldAttemptFallback(after: .uncertain(reason: "x")))
        XCTAssertFalse(InsertionOrchestrator.shouldAttemptFallback(after: .permissionMissing))
        XCTAssertFalse(InsertionOrchestrator.shouldAttemptFallback(after: .deferredToReview))
    }

    func testClipboardRestoreOnlyWhenUntouched() {
        XCTAssertTrue(ClipboardPolicy.shouldRestorePasteboard(changeCountAfterPaste: 10, currentChangeCount: 10))
        XCTAssertFalse(ClipboardPolicy.shouldRestorePasteboard(changeCountAfterPaste: 10, currentChangeCount: 11))
    }

    func testDirectWriteConfirmationSignals() {
        let text = "hi 👋" // 4 characters, 5 UTF-16 units: AX ranges count UTF-16
        func confirmed(start: Int? = 5, echoed: String? = "", after: (location: Int, length: Int)? = nil, atRange: String? = nil, text: String = text) -> Bool {
            InsertionConfirmation.isConfirmed(
                insertedText: text, originalSelectionLocation: start,
                echoedSelectedText: echoed, selectionAfter: after, textAtInsertedRange: atRange
            )
        }
        XCTAssertTrue(confirmed(echoed: text))                          // selection still equals text
        XCTAssertTrue(confirmed(atRange: text))                         // bounded read of inserted range
        XCTAssertTrue(confirmed(after: (location: 10, length: 0)))      // caret collapsed after text (AppKit)
        XCTAssertFalse(confirmed(after: (location: 5, length: 0), atRange: "other")) // caret unchanged
        XCTAssertFalse(confirmed(echoed: nil, after: (location: 10, length: 3)))     // non-empty selection
        XCTAssertFalse(confirmed(start: nil, echoed: nil, after: (location: 10, length: 0))) // no anchor
        XCTAssertFalse(confirmed(after: (location: 5, length: 0), atRange: "", text: "")) // empty never confirms
    }
}
