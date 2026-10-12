import Foundation

// MARK: - Clipboard restoration policy (pure, tested)

public enum ClipboardPolicy {
    /// Restore the saved clipboard ONLY if nobody else touched the pasteboard
    /// since we pasted. Inputs are NSPasteboard changeCounts:
    /// - `changeCountAfterPaste`: count right after we set the transcript + sent Cmd+V
    /// - `currentChangeCount`: count at restore time
    ///
    /// If they differ, another process wrote to the clipboard (or the paste
    /// hasn't been consumed yet and something reordered) — restoring would
    /// destroy user data, so we leave the transcript on the clipboard and say so.
    /// No fixed sleep makes this universally reliable; the changeCount check is
    /// the mechanism, and the Copy action is the documented fallback.
    public static func shouldRestorePasteboard(
        changeCountAfterPaste: Int,
        currentChangeCount: Int
    ) -> Bool {
        currentChangeCount == changeCountAfterPaste
    }
}
