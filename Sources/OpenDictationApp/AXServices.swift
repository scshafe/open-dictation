import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OpenDictationCore

// MARK: - AX helpers

private enum AX {
    static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element, attribute) as? String
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    static func intAttribute(_ element: AXUIElement, _ attribute: String) -> Int? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        return (value as? NSNumber)?.intValue
    }

    /// Parameterized read of a bounded substring — never the whole value.
    static func string(_ element: AXUIElement, forRange range: CFRange) -> String? {
        var cfRange = range
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value
        ) == .success else { return nil }
        return value as? String
    }

    static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = copyAttribute(element, attribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = copyAttribute(element, attribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    static func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let value = copyAttribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }
}

// MARK: - Destination capture (minimal AX facts)

final class AXDestinationService: DestinationService {
    /// Fingerprint reads at most this many characters of the field value.
    static let fingerprintPrefixLength = 200

    var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    func promptForTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func captureSnapshot() -> DestinationSnapshot? { capture() }
    func currentSnapshot() -> DestinationSnapshot? { capture() }

    private func capture() -> DestinationSnapshot? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
        // Never target ourselves: if our own window is frontmost, there is no
        // external destination — the transcript will be retained for review.
        if frontmost.bundleIdentifier == Bundle.main.bundleIdentifier { return nil }
        let pid = frontmost.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        // Focused window identity — never the title (see windowIdentity).
        var windowFingerprint: Int?
        if let windowRef = AX.copyAttribute(appElement, kAXFocusedWindowAttribute),
           CFGetTypeID(windowRef) == AXUIElementGetTypeID() {
            let window = windowRef as! AXUIElement
            windowFingerprint = Self.windowIdentity(
                pid: pid,
                window: window,
                position: AX.point(window, kAXPositionAttribute),
                size: AX.size(window, kAXSizeAttribute)
            )
        }

        var role: String?
        var identifier: String?
        var selectedText: String?
        var range: CFRange?
        var fingerprint: Int?
        var isSecure = false
        if let focusedRef = AX.copyAttribute(appElement, kAXFocusedUIElementAttribute),
           CFGetTypeID(focusedRef) == AXUIElementGetTypeID() {
            let focused = focusedRef as! AXUIElement
            role = AX.stringAttribute(focused, kAXRoleAttribute)
            identifier = AX.stringAttribute(focused, kAXIdentifierAttribute)
            if let subrole = AX.stringAttribute(focused, kAXSubroleAttribute),
               subrole == "AXSecureTextField" {
                isSecure = true
            }
            if !isSecure {
                // Selection text only (short by nature).
                selectedText = AX.stringAttribute(focused, kAXSelectedTextAttribute)
                range = AX.selectedRange(focused)
                // Bounded fingerprint: character count + a short prefix read via
                // the string-for-range attribute. The full value is never
                // transferred out of the target app.
                if let count = AX.intAttribute(focused, kAXNumberOfCharactersAttribute) {
                    let prefixLength = min(max(count, 0), Self.fingerprintPrefixLength)
                    let prefix = prefixLength > 0
                        ? AX.string(focused, forRange: CFRange(location: 0, length: prefixLength))
                        : ""
                    var hasher = Hasher()
                    hasher.combine(prefix ?? "")
                    hasher.combine(count)
                    fingerprint = hasher.finalize()
                }
            }
        }

        return DestinationSnapshot(
            processID: pid,
            bundleIdentifier: frontmost.bundleIdentifier,
            windowNumber: windowFingerprint,
            focusedRole: role,
            focusedIdentifier: identifier,
            selectedText: selectedText,
            selectionLocation: range.map { $0.location },
            selectionLength: range.map { $0.length },
            valueFingerprint: fingerprint,
            isSecureField: isSecure,
            capturedAt: Date()
        )
    }
}

// MARK: - Window identity without the title

extension AXDestinationService {
    /// Stable identity for the focused window that does NOT involve its title.
    /// Titles change constantly in terminals (status in the title), browsers
    /// (page titles), chat apps (unread counts) and editors ("— Edited"), which
    /// made every insertion into such apps fail as "a different window is now
    /// focused". Preferred: the window server's window number, found by
    /// matching the AX window's bounds against the app's on-screen windows
    /// (public CGWindowList API; bounds need no Screen Recording permission).
    /// Survives moves and resizes because both sides are re-read live.
    /// Fallback when the match is not unique: a hash of role + bounds.
    static func windowIdentity(pid: pid_t, window: AXUIElement, position: CGPoint?, size: CGSize?) -> Int? {
        if let position, let size,
           let number = cgWindowNumber(pid: pid, matching: CGRect(origin: position, size: size)) {
            return number
        }
        guard position != nil || size != nil else { return nil }
        var hasher = Hasher()
        hasher.combine("bounds-fallback")
        if let role = AX.stringAttribute(window, kAXRoleAttribute) { hasher.combine(role) }
        if let subrole = AX.stringAttribute(window, kAXSubroleAttribute) { hasher.combine(subrole) }
        if let position { hasher.combine(Int(position.x.rounded())); hasher.combine(Int(position.y.rounded())) }
        if let size { hasher.combine(Int(size.width.rounded())); hasher.combine(Int(size.height.rounded())) }
        return hasher.finalize()
    }

    /// The single on-screen, normal-layer window of `pid` whose bounds match
    /// (±2 pt). AX and CGWindowList both use top-left-origin screen coordinates.
    static func cgWindowNumber(pid: pid_t, matching bounds: CGRect) -> Int? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        var matches: [Int] = []
        for info in list {
            guard let owner = info[kCGWindowOwnerPID as String] as? Int, owner == Int(pid),
                  (info[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict) else { continue }
            if abs(rect.origin.x - bounds.origin.x) <= 2, abs(rect.origin.y - bounds.origin.y) <= 2,
               abs(rect.width - bounds.width) <= 2, abs(rect.height - bounds.height) <= 2 {
                matches.append(number)
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

// MARK: - Faithful pasteboard save/restore

/// Saves every type on the general pasteboard so a compatibility paste can
/// restore the user's clipboard afterwards. Bounded: if the total exceeds
/// 32 MB the contents are left unrestored (transcript stays on the clipboard
/// and the UI says so) rather than copying unbounded data.
final class SavedPasteboard {
    static let maxBytes = 32 * 1024 * 1024
    private let entries: [(NSPasteboard.PasteboardType, Data)]

    private init(entries: [(NSPasteboard.PasteboardType, Data)]) {
        self.entries = entries
    }

    static func capture(_ pasteboard: NSPasteboard) -> SavedPasteboard? {
        guard let types = pasteboard.types else { return SavedPasteboard(entries: []) }
        var entries: [(NSPasteboard.PasteboardType, Data)] = []
        var total = 0
        for type in types {
            guard let data = pasteboard.data(forType: type) else { continue }
            total += data.count
            if total > maxBytes { return nil } // too big: do not attempt restore
            entries.append((type, data))
        }
        return SavedPasteboard(entries: entries)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if entries.isEmpty { return }
        pasteboard.declareTypes(entries.map(\.0), owner: nil)
        for (type, data) in entries {
            pasteboard.setData(data, forType: type)
        }
    }
}

// MARK: - Text insertion: targeted AX first, paste fallback second

final class AXInsertionService: TextInserter {
    func insertDirect(text: String, snapshot: DestinationSnapshot) async -> InsertionOutcome {
        guard AXIsProcessTrusted() else { return .permissionMissing }
        guard !snapshot.isSecureField else {
            return .unsupported(reason: "secure fields cannot receive inserted text")
        }
        // Target process must still exist.
        guard NSRunningApplication(processIdentifier: snapshot.processID) != nil else {
            return .failed(reason: "target application closed")
        }
        let appElement = AXUIElementCreateApplication(snapshot.processID)
        guard let focusedRef = AX.copyAttribute(appElement, kAXFocusedUIElementAttribute),
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return .failed(reason: "target field is no longer focused")
        }
        let element = focusedRef as! AXUIElement
        if let subrole = AX.stringAttribute(element, kAXSubroleAttribute),
           subrole == "AXSecureTextField" {
            return .unsupported(reason: "secure fields cannot receive inserted text")
        }
        let attribute = kAXSelectedTextAttribute as CFString
        // Read first: unsupported controls fail here (attributeUnsupported).
        guard AX.copyAttribute(element, kAXSelectedTextAttribute) != nil ||
            AX.isSettable(element, kAXSelectedTextAttribute) else {
            return .unsupported(reason: "this field does not support direct insertion")
        }
        guard AX.isSettable(element, kAXSelectedTextAttribute) else {
            return .unsupported(reason: "this field is read-only")
        }
        // Insertion point right before the write. The destination was validated
        // against the snapshot moments ago; the live read is the precise anchor.
        let startLocation = AX.selectedRange(element)?.location ?? snapshot.selectionLocation
        // Setting kAXSelectedText replaces the current selection, exactly like
        // typing over it; with an empty selection it inserts at the caret.
        // The full field value is never replaced.
        let setError = AXUIElementSetAttributeValue(element, attribute, text as CFString)
        switch setError {
        case .success:
            break
        case .attributeUnsupported:
            return .unsupported(reason: "this field does not support direct insertion")
        case .apiDisabled:
            return .permissionMissing
        default:
            return .failed(reason: "accessibility write failed (\(setError.rawValue))")
        }
        // Read-back confirmation. AppKit text views collapse the selection to a
        // caret AFTER the inserted text, so an echoed selection is only one of
        // three accepted signals (InsertionConfirmation, unit-tested):
        //   1. the selected text still equals the transcript,
        //   2. the text at [start, start + length) reads back as the transcript
        //      (bounded string-for-range read, never the whole value),
        //   3. a zero-length selection sits exactly at start + length.
        // No signal → uncertain, never followed by a paste (duplication risk).
        let echoed = AX.stringAttribute(element, kAXSelectedTextAttribute)
        let after = AX.selectedRange(element)
        var textAtRange: String?
        if let startLocation {
            textAtRange = AX.string(element, forRange: CFRange(location: startLocation, length: text.utf16.count))
        }
        let confirmed = InsertionConfirmation.isConfirmed(
            insertedText: text,
            originalSelectionLocation: startLocation,
            echoedSelectedText: echoed,
            selectionAfter: after.map { (location: $0.location, length: $0.length) },
            textAtInsertedRange: textAtRange
        )
        return confirmed
            ? .inserted(method: "accessibility")
            : .uncertain(reason: "direct write sent but could not be confirmed")
    }

    func insertViaPaste(text: String, snapshot: DestinationSnapshot) async -> InsertionOutcome {
        guard AXIsProcessTrusted() else { return .permissionMissing }
        guard !snapshot.isSecureField else {
            return .unsupported(reason: "secure fields cannot receive inserted text")
        }
        let pasteboard = NSPasteboard.general
        let saved = SavedPasteboard.capture(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let afterSet = pasteboard.changeCount

        guard postCommandV() else {
            if let saved { saved.restore(to: pasteboard) }
            return .failed(reason: "could not send the paste keystroke")
        }
        // Heuristic wait for asynchronous paste consumption. This is NOT a
        // reliability mechanism — the changeCount check below is. See
        // ClipboardPolicy.shouldRestorePasteboard.
        try? await Task.sleep(nanoseconds: 250_000_000)
        if ClipboardPolicy.shouldRestorePasteboard(
            changeCountAfterPaste: afterSet,
            currentChangeCount: pasteboard.changeCount
        ) {
            if let saved {
                saved.restore(to: pasteboard)
            } else {
                pasteboard.clearContents() // oversized original; leave clean + say so
                return .uncertain(reason: "paste sent; previous clipboard was too large to restore")
            }
            return .uncertain(reason: "paste sent; clipboard restored")
        }
        return .uncertain(reason: "paste sent; clipboard left with the transcript")
    }

    private func postCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        // Virtual key 0x09 = 'v'. Command flag on both down and up.
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
