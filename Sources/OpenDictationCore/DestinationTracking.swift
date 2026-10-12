import Foundation

// MARK: - Destination snapshot (minimal AX facts, no document contents)

/// What the AX backend must capture *before* the panel appears: enough to
/// revalidate "same field, same caret, same selection" later, without copying
/// document bodies. `valueFingerprint` is a hash of a small prefix, not text.
public struct DestinationSnapshot: Equatable, Sendable, Codable {
    public var processID: Int32
    public var bundleIdentifier: String?
    public var windowNumber: Int?
    public var focusedRole: String?
    public var focusedIdentifier: String?
    public var selectedText: String?       // selection text only (usually short)
    public var selectionLocation: Int?
    public var selectionLength: Int?
    public var valueFingerprint: Int?      // hash of a small value prefix
    public var isSecureField: Bool
    public var capturedAt: Date

    public init(
        processID: Int32,
        bundleIdentifier: String? = nil,
        windowNumber: Int? = nil,
        focusedRole: String? = nil,
        focusedIdentifier: String? = nil,
        selectedText: String? = nil,
        selectionLocation: Int? = nil,
        selectionLength: Int? = nil,
        valueFingerprint: Int? = nil,
        isSecureField: Bool = false,
        capturedAt: Date = Date()
    ) {
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.windowNumber = windowNumber
        self.focusedRole = focusedRole
        self.focusedIdentifier = focusedIdentifier
        self.selectedText = selectedText
        self.selectionLocation = selectionLocation
        self.selectionLength = selectionLength
        self.valueFingerprint = valueFingerprint
        self.isSecureField = isSecureField
        self.capturedAt = capturedAt
    }
}

public enum DestinationCheck: Equatable, Sendable {
    case valid
    /// Destination positively changed: refuse automatic insertion, keep transcript.
    case stale(String)
    /// Identity uncertain (target gone, permission lost, unreadable): refuse, keep transcript.
    case unknown(String)

    public var isValid: Bool {
        if case .valid = self { return true }
        return false
    }

    public var reason: String? {
        switch self {
        case .valid: return nil
        case .stale(let r), .unknown(let r): return r
        }
    }
}

public enum DestinationPolicy {
    /// Revalidate `current` against `original`. Conservative by design:
    /// any meaningful change — or any uncertainty — refuses insertion.
    /// A focus change away and back does NOT count as survival: the caret /
    /// selection comparison below will reject it unless provably identical,
    /// and callers treat `.unknown` as refusal too.
    ///
    /// Known limit (documented, not fixable): there is an unavoidable race
    /// between this validation and the cross-app keystroke/paste that follows.
    /// The window is minimized (validate immediately before inserting) but the
    /// insertion cannot be claimed atomic.
    public static func validate(original: DestinationSnapshot, current: DestinationSnapshot?) -> DestinationCheck {
        guard let current else {
            return .unknown("target application or field is no longer available")
        }
        if current.isSecureField || original.isSecureField {
            return .stale("secure field: insertion refused")
        }
        if current.processID != original.processID {
            return .stale("a different application is now active")
        }
        if let a = original.bundleIdentifier, let b = current.bundleIdentifier, a != b {
            return .stale("a different application is now active")
        }
        if let a = original.windowNumber, let b = current.windowNumber, a != b {
            return .stale("a different window is now focused")
        }
        if let a = original.focusedRole, let b = current.focusedRole, a != b {
            return .stale("focus moved to a different field")
        }
        if let a = original.focusedIdentifier, let b = current.focusedIdentifier, a != b {
            return .stale("focus moved to a different field")
        }
        // Caret / selection must be provably unchanged.
        if original.selectionLocation != current.selectionLocation ||
            original.selectionLength != current.selectionLength {
            return .stale("caret position or selection changed")
        }
        if original.selectedText != current.selectedText {
            return .stale("selected text changed")
        }
        if let a = original.valueFingerprint, let b = current.valueFingerprint, a != b {
            return .stale("field contents changed")
        }
        return .valid
    }
}

// MARK: - Backend boundary (AX lives in the App target)

public protocol DestinationService {
    /// Capture the current destination (frontmost app + focused field).
    /// Returns nil when unidentifiable — never throws for "unknown".
    func captureSnapshot() -> DestinationSnapshot?
    /// Re-read the destination for validation immediately before insertion.
    func currentSnapshot() -> DestinationSnapshot?
    var accessibilityTrusted: Bool { get }
}
