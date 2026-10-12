import Foundation

// MARK: - Session phases and transitions
//
// Single ownership point for "what state is a dictation in".
// Allowed transitions are explicit so UI, audio, network, and insertion code
// cannot drift into impossible combinations (e.g. inserting a canceled session).

public enum SessionPhase: String, Equatable, Sendable, Codable {
    case idle
    case preparing    // permission / device / destination capture, before audio starts
    case recording
    case transcribing // audio finalized, request in flight (or queued for retry)
    case resultReady  // final transcript available, not yet committed anywhere
    case inserting    // exactly-once insertion attempt in progress
    case completed    // terminal: transcript delivered or explicitly kept/dismissed
    case canceled     // terminal: user canceled; must never insert later
    case failed       // error state; may be retryable (audio retained) or terminal
}

public struct SessionTransition: Sendable {
    /// Returns true if `to` is a legal successor of `from`.
    public static func isAllowed(from: SessionPhase, to: SessionPhase) -> Bool {
        switch (from, to) {
        case (.idle, .preparing),
             (.preparing, .recording),
             (.preparing, .failed),
             (.preparing, .canceled),
             (.recording, .transcribing), // Stop
             (.recording, .canceled),     // Cancel
             (.recording, .failed),
             (.transcribing, .resultReady),
             (.transcribing, .failed),
             (.transcribing, .canceled),
             (.resultReady, .inserting),
             (.resultReady, .completed),   // review/copy path: user keeps it
             (.resultReady, .transcribing),// re-transcribe (kept audio)
             (.resultReady, .canceled),    // explicit discard
             (.inserting, .completed),     // inserted (or outcome recorded)
             (.inserting, .resultReady),   // insertion refused/failed: result retained
             (.inserting, .canceled),
             (.failed, .transcribing),     // explicit retry
             (.failed, .canceled):         // explicit discard
            return true
        default:
            return false
        }
    }

    public static var terminalPhases: Set<SessionPhase> {
        [.completed, .canceled]
    }

    /// `failed` is terminal only when the session is not retryable.
    public static func isTerminal(phase: SessionPhase, retryable: Bool) -> Bool {
        if terminalPhases.contains(phase) { return true }
        return phase == .failed && !retryable
    }
}

// MARK: - Session origin

public enum SessionOrigin: Equatable, Sendable {
    /// Recording started inside the app's own window. Never infer an external target.
    case inApp
    /// Recording started via global shortcut / menu for another app.
    /// The snapshot is nil when the destination could not be identified;
    /// such sessions keep their transcript for review/copy instead of guessing.
    case external(DestinationSnapshot?)
}

// MARK: - Session model

public struct DictationSession: Identifiable, Equatable {
    public let id: UUID
    public var phase: SessionPhase
    public var origin: SessionOrigin
    /// Snapshot of provider settings taken when the session started (or when
    /// an explicit retry began). Editing Settings mid-flight never mutates it.
    public var configSnapshot: ProviderConfig?
    /// Device-native capture file (deleted after conversion or discard).
    public var captureURL: URL?
    /// Converted upload payload (mono 16-bit PCM WAV). Retained only while a
    /// failed session is available for explicit retry.
    public var audioURL: URL?
    public var transcript: String?
    public var errorMessage: String?
    /// True when the failure keeps audio for an explicit retry.
    public var retryable: Bool
    /// Exactly-once insertion guard. Set before the first attempt; concurrent
    /// or repeated insert calls for this session are refused.
    public var insertionAttempted: Bool
    public var insertionOutcome: InsertionOutcome?
    /// Set when the user opens the transcript editor (or otherwise breaks the
    /// destination chain). Automatic insertion stays disabled until a fresh
    /// destination is explicitly established.
    public var autoInsertInvalidated: Bool
    public var createdAt: Date
    public var recordingDuration: TimeInterval

    public init(
        id: UUID = UUID(),
        phase: SessionPhase = .idle,
        origin: SessionOrigin,
        configSnapshot: ProviderConfig? = nil
    ) {
        self.id = id
        self.phase = phase
        self.origin = origin
        self.configSnapshot = configSnapshot
        self.captureURL = nil
        self.audioURL = nil
        self.transcript = nil
        self.errorMessage = nil
        self.retryable = false
        self.insertionAttempted = false
        self.insertionOutcome = nil
        self.autoInsertInvalidated = false
        self.createdAt = Date()
        self.recordingDuration = 0
    }

    /// External destination attached at session start, if any.
    public var externalDestination: DestinationSnapshot? {
        if case .external(let snap) = origin { return snap }
        return nil
    }

    public var isExternal: Bool {
        if case .external = origin { return true }
        return false
    }
}
