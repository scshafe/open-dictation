import Foundation

// MARK: - Insertion modes and outcomes

public enum InsertionMode: String, Codable, Sendable, CaseIterable {
    /// Attempt one insertion after transcription, only if the destination
    /// revalidates. Otherwise retain the transcript for copy/explicit insert.
    case automaticWhenSafe
    /// Never insert automatically; always retain for review/copy.
    case reviewOnly

    public var displayName: String {
        switch self {
        case .automaticWhenSafe: return "Insert automatically when safe"
        case .reviewOnly: return "Review / copy (never auto-insert)"
        }
    }
}

public enum InsertionOutcome: Equatable, Sendable {
    /// Text was written through the named method ("accessibility" or "paste").
    case inserted(method: String)
    /// Destination changed or identity uncertain: refused, transcript retained.
    case skippedStale(reason: String)
    /// Field/app cannot accept insertion (unsupported control, secure field).
    case unsupported(reason: String)
    /// Attempt confirmed failed. Transcript retained; no automatic re-paste.
    case failed(reason: String)
    /// Attempt sent but completion could not be confirmed (notably paste).
    /// Treated as terminal for this session: never followed by another paste.
    case uncertain(reason: String)
    /// Cross-app permission missing. Transcript retained for manual copy.
    case permissionMissing
    /// User chose review mode / deferred.
    case deferredToReview

    public var userMessage: String {
        switch self {
        case .inserted(let m): return "Inserted (\(m))."
        case .skippedStale(let r): return "Not inserted — \(r). Transcript kept for copy."
        case .unsupported(let r): return "Cannot insert here — \(r). Transcript kept for copy."
        case .failed(let r): return "Insertion failed (\(r)). Transcript kept; use Copy."
        case .uncertain(let r): return "Insertion may not have completed (\(r)). Check the target; transcript kept."
        case .permissionMissing: return "Accessibility permission is missing. Transcript kept — use Copy, or grant access and Insert."
        case .deferredToReview: return "Transcript kept for review."
        }
    }
}

public enum InsertionOrchestrator {
    /// Fallback policy: clipboard-and-paste runs ONLY when direct insertion
    /// positively reports `.unsupported`. After `.failed` or `.uncertain` we
    /// must not paste, or the transcript could be duplicated. After success or
    /// refusal there is nothing to fall back to.
    public static func shouldAttemptFallback(after direct: InsertionOutcome) -> Bool {
        if case .unsupported = direct { return true }
        return false
    }
}

// MARK: - Direct-write confirmation (pure, tested)

public enum InsertionConfirmation {
    /// Decide whether a targeted Accessibility write can be reported as
    /// `.inserted`. Apps differ in what they expose after a write: some keep
    /// the new text selected, AppKit text views collapse the selection to a
    /// caret AFTER the inserted text. Any ONE positive signal confirms; with
    /// none the caller reports `.uncertain` and must never paste.
    ///
    /// - insertedText: the transcript that was written
    /// - originalSelectionLocation: selection start (UTF-16 offset) right before the write
    /// - echoedSelectedText: selected text read back after the write
    /// - selectionAfter: selected range read back after the write
    /// - textAtInsertedRange: bounded read of [start, start + length) after the write
    public static func isConfirmed(
        insertedText: String,
        originalSelectionLocation: Int?,
        echoedSelectedText: String?,
        selectionAfter: (location: Int, length: Int)?,
        textAtInsertedRange: String?
    ) -> Bool {
        guard !insertedText.isEmpty else { return false }
        if echoedSelectedText == insertedText { return true }
        if textAtInsertedRange == insertedText { return true }
        if let start = originalSelectionLocation, let after = selectionAfter,
           after.length == 0, after.location == start + insertedText.utf16.count {
            return true
        }
        return false
    }
}

// MARK: - Backend boundary (AX + pasteboard live in the App target)

public protocol TextInserter {
    /// Targeted Accessibility write at the validated selection.
    func insertDirect(text: String, snapshot: DestinationSnapshot) async -> InsertionOutcome
    /// Clipboard-and-paste compatibility fallback.
    func insertViaPaste(text: String, snapshot: DestinationSnapshot) async -> InsertionOutcome
}
