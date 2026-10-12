import Combine
import Foundation

// MARK: - Recording backend boundary (AVAudioEngine lives in AudioRecorder)

public enum RecorderError: Error, Equatable {
    case permissionDenied
    case noInputDevice
    case engineStartFailed(String)
    case alreadyRecording
    case notRecording
    case writeFailed(String)
    case deviceDisappeared
    case durationLimitReached

    public var userMessage: String {
        switch self {
        case .permissionDenied: return "Microphone access was denied. Grant access in System Settings → Privacy & Security → Microphone."
        case .noInputDevice: return "No input device found. Connect a microphone and try again."
        case .engineStartFailed(let d): return "Could not start recording (\(d))."
        case .alreadyRecording: return "Already recording."
        case .notRecording: return "Not recording."
        case .writeFailed(let d): return "Recording write failed (\(d))."
        case .deviceDisappeared: return "The input device disappeared. Recording stopped."
        case .durationLimitReached: return "Recording stopped at the duration limit."
        }
    }
}

public protocol AudioRecordingService: AnyObject {
    var onLevel: ((Float) -> Void)? { get set }
    var onDuration: ((TimeInterval) -> Void)? { get set }
    var onOverload: (() -> Void)? { get set }
    var onDeviceChange: ((String) -> Void)? { get set }
    /// Begin capture. Throws without side effects on failure (UI must not stick in Recording).
    func start() throws
    /// Stop capture and return the device-native capture file URL.
    func stop() throws -> URL
    /// Discard capture. Idempotent.
    func cancel()
}

@MainActor
public protocol SessionConfigSource: AnyObject {
    func currentSettings() -> AppSettings
    func currentToken() -> String?
}

// MARK: - Session coordinator: one owner for state, cleanup, and stale guards

@MainActor
public final class SessionCoordinator: ObservableObject {
    @Published public private(set) var activeSession: DictationSession?
    @Published public private(set) var retainedSessions: [DictationSession] = []
    @Published public private(set) var micLevel: Float = 0
    @Published public private(set) var recordingDuration: TimeInterval = 0
    @Published public private(set) var noticeMessage: String?
    @Published public private(set) var isTranscribing = false

    public enum StartResult: Equatable {
        case started
        case busy(String)
        case invalidEndpoint(String)
    }

    private let makeRecorder: () -> AudioRecordingService
    private let converter: AudioConverting
    private let makeProvider: () -> TranscriptionProvider
    private let inserter: TextInserter
    private let destinations: DestinationService
    private let configSource: SessionConfigSource
    private let microphoneStatus: () -> MicStatus
    private let requestMicrophone: () async -> Bool
    private let tempStore: TempAudioStore
    private let maxRetained = 10

    /// Optional diagnostic sink (the app routes it to the unified log). Lines
    /// carry phase/outcome kinds and refusal reasons only — never transcript
    /// text, audio, or credentials — so "why wasn't it inserted?" is answerable
    /// from `log show --predicate 'process == "OpenDictation"'`.
    public var diagnostics: ((String) -> Void)?

    private var recorder: AudioRecordingService?
    private var transcribeTask: Task<Void, Never>?
    /// Stale-callback guard: bumped on every start/cancel/retry. Async
    /// continuations capture (sessionID, generation) and bail out on mismatch,
    /// so a canceled session can never insert text from a delayed callback.
    private var generation = 0
    private var durationLimitSeconds: TimeInterval = 0

    public init(
        makeRecorder: @escaping () -> AudioRecordingService,
        converter: AudioConverting,
        makeProvider: @escaping () -> TranscriptionProvider,
        inserter: TextInserter,
        destinations: DestinationService,
        configSource: SessionConfigSource,
        microphoneStatus: @escaping () -> MicStatus = MicrophonePermission.status,
        requestMicrophone: @escaping () async -> Bool = MicrophonePermission.request,
        tempStore: TempAudioStore = .shared
    ) {
        self.makeRecorder = makeRecorder
        self.converter = converter
        self.makeProvider = makeProvider
        self.inserter = inserter
        self.destinations = destinations
        self.configSource = configSource
        self.microphoneStatus = microphoneStatus
        self.requestMicrophone = requestMicrophone
        self.tempStore = tempStore
    }

    // MARK: - Starting

    /// Global-shortcut / menu path. Captures the destination BEFORE the panel
    /// appears (caller shows UI in response to published state).
    public func startExternalSession() -> StartResult {
        let snapshot = destinations.captureSnapshot()
        if let snapshot {
            diagnostics?("external session: destination captured pid=\(snapshot.processID) bundle=\(snapshot.bundleIdentifier ?? "?") role=\(snapshot.focusedRole ?? "?") selection=\(snapshot.selectionLocation.map(String.init) ?? "?") accessibilityTrusted=\(destinations.accessibilityTrusted)")
        } else {
            diagnostics?("external session: no destination captured (frontmost is this app, or the target is unreadable) accessibilityTrusted=\(destinations.accessibilityTrusted)")
        }
        return begin(origin: .external(snapshot))
    }

    /// Main-window path. Never infers an external target.
    public func startInAppSession() -> StartResult {
        begin(origin: .inApp)
    }

    private func begin(origin: SessionOrigin) -> StartResult {
        if let active = activeSession, isLive(phase: active.phase) {
            return .busy("A recording is already in progress. Stop or cancel it first.")
        }
        // Microphone permission gate. First launch shows the system prompt from
        // this user-initiated flow; the session continues in .preparing.
        switch microphoneStatus() {
        case .authorized:
            break
        case .denied:
            return .busy(RecorderError.permissionDenied.userMessage)
        case .notDetermined:
            generation += 1
            let gen = generation
            activeSession = DictationSession(phase: .preparing, origin: origin)
            noticeMessage = "Waiting for microphone permission…"
            Task { [weak self] in
                guard let self else { return }
                let granted = await self.requestMicrophone()
                await MainActor.run { [weak self] in
                    guard let self, self.generation == gen else { return }
                    if granted {
                        self.clearNotice()
                        // Restart cleanly now that permission exists.
                        self.activeSession = nil
                        _ = self.begin(origin: origin)
                    } else {
                        self.activeSession?.phase = .failed
                        self.activeSession?.errorMessage = RecorderError.permissionDenied.userMessage
                        self.activeSession?.retryable = false
                        self.noticeMessage = nil
                    }
                }
            }
            return .started
        }
        let settings = configSource.currentSettings()
        guard let config = settings.providerConfig(bearerToken: configSource.currentToken()) else {
            return .invalidEndpoint("The endpoint URL is invalid. Open Settings and enter the full transcription URL.")
        }
        // Never erase an uncommitted transcript: retain the previous session.
        if let previous = activeSession, previous.transcript != nil || (previous.phase == .failed && previous.retryable) {
            pushRetained(previous)
        } else if let previous = activeSession {
            cleanupFiles(for: previous)
        }
        generation += 1
        durationLimitSeconds = settings.effectiveRecordingLimitSeconds
        var session = DictationSession(phase: .preparing, origin: origin, configSnapshot: config)
        activeSession = session
        micLevel = 0
        recordingDuration = 0
        noticeMessage = nil

        let recorder = makeRecorder()
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.micLevel = level }
        }
        recorder.onDuration = { [weak self] duration in
            Task { @MainActor in self?.handleDurationTick(duration) }
        }
        recorder.onOverload = { [weak self] in
            Task { @MainActor in
                self?.noticeMessage = "Audio overload: some samples were dropped. Close heavy apps and retry."
            }
        }
        recorder.onDeviceChange = { [weak self] detail in
            Task { @MainActor in self?.handleDeviceChange(detail) }
        }
        do {
            try recorder.start()
        } catch let error as RecorderError {
            activeSession?.phase = .failed
            activeSession?.errorMessage = error.userMessage
            activeSession?.retryable = false
            self.recorder = nil
            return .busy(error.userMessage)
        } catch {
            activeSession?.phase = .failed
            activeSession?.errorMessage = "Could not start recording."
            activeSession?.retryable = false
            self.recorder = nil
            return .busy("Could not start recording.")
        }
        self.recorder = recorder
        session.phase = .recording
        activeSession = session
        return .started
    }

    private func isLive(phase: SessionPhase) -> Bool {
        switch phase {
        case .preparing, .recording, .transcribing, .inserting: return true
        case .idle, .resultReady, .completed, .canceled, .failed: return false
        }
    }

    // MARK: - Stop (transcribe) vs Cancel (discard)

    /// Stop requests a transcript. Idempotent: a second stop while already
    /// transcribing is ignored (double-stop safety). Capture finalization is
    /// synchronous (tap removed, mic released NOW); only conversion and the
    /// network request run in the cancellable task.
    public func stopAndTranscribe() {
        guard var session = activeSession, session.phase == .recording else { return }
        session.phase = .transcribing
        activeSession = session
        isTranscribing = true
        micLevel = 0

        let sid = session.id
        let gen = generation
        let recorder = self.recorder
        self.recorder = nil
        let captureURL: URL
        do {
            guard let recorder else { throw RecorderError.notRecording }
            captureURL = try recorder.stop()
        } catch {
            failActive(sessionID: sid, message: "Could not finalize the recording.", retryable: false)
            return
        }
        activeSession?.captureURL = captureURL
        activeSession?.recordingDuration = recordingDuration

        transcribeTask?.cancel()
        transcribeTask = Task { [weak self] in
            guard let self else { return }
            await self.convertAndTranscribe(sessionID: sid, generation: gen, captureURL: captureURL)
        }
    }

    private func convertAndTranscribe(sessionID: UUID, generation gen: Int, captureURL: URL) async {
        guard self.generation == gen, let session = activeSession, session.id == sessionID else {
            tempStore.delete(captureURL) // superseded before conversion started
            return
        }

        // Convert off the main actor (blocking resample work).
        let converted: URL
        do {
            converted = try await Task.detached { [converter] in
                try converter.convertToUploadWAV(source: captureURL)
            }.value
        } catch is CancellationError {
            return // generation was bumped; stale guard below also drops this path
        } catch {
            guard self.generation == gen, activeSession?.id == sessionID else {
                tempStore.delete(captureURL)
                return
            }
            tempStore.delete(captureURL)
            failActive(sessionID: sessionID, message: "Audio conversion failed.", retryable: false)
            return
        }
        tempStore.delete(captureURL)
        guard self.generation == gen, activeSession?.id == sessionID else {
            tempStore.delete(converted) // superseded: never transcribe/insert late
            return
        }
        activeSession?.captureURL = nil
        activeSession?.audioURL = converted

        // 3. Transcribe with the session's snapshotted config.
        await transcribeAudio(sessionID: sessionID, generation: gen, audioURL: converted, config: session.configSnapshot)
    }

    private func transcribeAudio(sessionID: UUID, generation gen: Int, audioURL: URL, config: ProviderConfig?) async {
        guard let config else {
            failActive(sessionID: sessionID, message: "Missing provider configuration.", retryable: false)
            return
        }
        let provider = makeProvider()
        do {
            let result = try await provider.transcribe(audioURL: audioURL, config: config)
            try Task.checkCancellation()
            guard self.generation == gen, var session = activeSession, session.id == sessionID else {
                return // stale: canceled or superseded; result discarded, temp cleaned by cancel path
            }
            session.transcript = result.text
            session.errorMessage = nil
            session.retryable = false
            session.insertionAttempted = false // new text: new insertion lifecycle
            session.insertionOutcome = nil
            session.phase = .resultReady
            activeSession = session
            isTranscribing = false
            // Success: audio no longer needed (no silent archives).
            tempStore.delete(audioURL)
            activeSession?.audioURL = nil

            await maybeAutoInsert(sessionID: sessionID, generation: gen)
        } catch is CancellationError {
            return
        } catch let error as ProviderError {
            guard self.generation == gen, activeSession?.id == sessionID else { return }
            handleProviderFailure(sessionID: sessionID, error: error)
        } catch {
            guard self.generation == gen, activeSession?.id == sessionID else { return }
            handleProviderFailure(sessionID: sessionID, error: .transport("unexpected error"))
        }
    }

    private func handleProviderFailure(sessionID: UUID, error: ProviderError) {
        isTranscribing = false
        guard var session = activeSession, session.id == sessionID else { return }
        if error == .cancelled {
            session.phase = .canceled
            session.retryable = false
            cleanupFiles(for: session)
            session.captureURL = nil
            session.audioURL = nil
        } else {
            session.phase = .failed
            session.errorMessage = error.userMessage
            session.retryable = error.keepsAudioForRetry
            if !error.keepsAudioForRetry {
                // Terminal failure: no silent audio retention.
                cleanupFiles(for: session)
                session.captureURL = nil
                session.audioURL = nil
            }
            // Retryable failure: converted WAV is retained for explicit Retry.
        }
        activeSession = session
    }

    private func failActive(sessionID: UUID, message: String, retryable: Bool) {
        isTranscribing = false
        guard var session = activeSession, session.id == sessionID else { return }
        if let captureURL = session.captureURL { tempStore.delete(captureURL) }
        if !retryable, let audioURL = session.audioURL { tempStore.delete(audioURL) }
        session.captureURL = nil
        if !retryable { session.audioURL = nil }
        session.phase = .failed
        session.errorMessage = message
        session.retryable = retryable
        activeSession = session
    }

    /// Cancel discards the pending operation. Idempotent. A canceled session
    /// never inserts text later: generation is bumped and temp files removed.
    public func cancelActive() {
        generation += 1
        transcribeTask?.cancel()
        transcribeTask = nil
        recorder?.cancel()
        recorder = nil
        micLevel = 0
        isTranscribing = false
        guard var session = activeSession else { return }
        switch session.phase {
        case .preparing, .recording, .transcribing, .inserting:
            cleanupFiles(for: session)
            session.captureURL = nil
            session.audioURL = nil
            session.phase = .canceled
            session.retryable = false
            session.transcript = nil
            session.errorMessage = nil
            activeSession = session
        case .resultReady, .failed, .completed:
            // Cancel on a settled session = explicit discard.
            discardSession(id: session.id)
        case .idle, .canceled:
            break
        }
    }

    // MARK: - Retry (explicit only; never automatic)

    /// Retry re-snapshots the CURRENT settings so the user can fix the URL or
    /// token and then retry with the retained audio. Documented behavior.
    public func retry(sessionID: UUID) {
        if let active = activeSession, isLive(phase: active.phase) {
            noticeMessage = "Finish or cancel the current recording first."
            return
        }
        var session: DictationSession?
        if activeSession?.id == sessionID { session = activeSession }
        else if let found = retainedSessions.first(where: { $0.id == sessionID }) {
            session = found
            retainedSessions.removeAll { $0.id == sessionID }
            if let current = activeSession { pushRetained(current) }
            activeSession = session
        }
        guard var target = session,
              target.phase == .failed, target.retryable,
              let audioURL = target.audioURL
        else {
            noticeMessage = "That session cannot be retried."
            return
        }
        let settings = configSource.currentSettings()
        guard let config = settings.providerConfig(bearerToken: configSource.currentToken()) else {
            noticeMessage = "The endpoint URL is invalid. Fix it in Settings first."
            return
        }
        generation += 1
        let gen = generation
        target.configSnapshot = config
        target.phase = .transcribing
        target.errorMessage = nil
        activeSession = target
        isTranscribing = true
        transcribeTask?.cancel()
        transcribeTask = Task { [weak self] in
            guard let self else { return }
            await self.transcribeAudio(sessionID: sessionID, generation: gen, audioURL: audioURL, config: config)
        }
    }

    // MARK: - Insertion

    private func maybeAutoInsert(sessionID: UUID, generation gen: Int) async {
        guard var session = activeSession, session.id == sessionID else { return }
        guard session.isExternal else { return } // in-app: transcript stays in the window
        guard !session.autoInsertInvalidated else {
            diagnostics?("auto-insert skipped: editor was opened (destination chain broken)")
            return
        }
        let mode = configSource.currentSettings().insertionMode
        guard mode == .automaticWhenSafe else {
            diagnostics?("auto-insert skipped: insertion mode is review/copy")
            return
        }
        guard let text = session.transcript, session.phase == .resultReady else { return }
        session.phase = .inserting
        session.insertionAttempted = true
        activeSession = session

        let original = session.externalDestination
        // Revalidate immediately before inserting (minimizes the race window).
        let check: DestinationCheck
        if let original {
            check = DestinationPolicy.validate(original: original, current: destinations.currentSnapshot())
        } else {
            check = .unknown("no destination was captured")
        }
        guard self.generation == gen, activeSession?.id == sessionID else { return }
        diagnostics?("auto-insert destination check: \(check)")
        switch check {
        case .valid:
            guard let original else {
                finishInsertion(sessionID: sessionID, outcome: .unsupported(reason: "no destination"), completed: false)
                return
            }
            let direct = await inserter.insertDirect(text: text, snapshot: original)
            guard self.generation == gen, activeSession?.id == sessionID else { return }
            if InsertionOrchestrator.shouldAttemptFallback(after: direct) {
                let viaPaste = await inserter.insertViaPaste(text: text, snapshot: original)
                guard self.generation == gen, activeSession?.id == sessionID else { return }
                finishInsertion(sessionID: sessionID, outcome: viaPaste, completed: isInserted(viaPaste))
            } else {
                finishInsertion(sessionID: sessionID, outcome: direct, completed: isInserted(direct))
            }
        case .stale(let reason):
            finishInsertion(sessionID: sessionID, outcome: .skippedStale(reason: reason), completed: false)
        case .unknown(let reason):
            finishInsertion(sessionID: sessionID, outcome: .skippedStale(reason: reason), completed: false)
        }
    }

    private func isInserted(_ outcome: InsertionOutcome) -> Bool {
        if case .inserted = outcome { return true }
        return false
    }

    private func finishInsertion(sessionID: UUID, outcome: InsertionOutcome, completed: Bool) {
        guard var session = activeSession, session.id == sessionID else { return }
        diagnostics?("auto-insert outcome: \(outcome)")
        session.insertionOutcome = outcome
        session.phase = completed ? .completed : .resultReady
        activeSession = session
    }

    /// Explicit user-triggered insertion for an external session with a
    /// transcript. Revalidates a FRESH capture against the ORIGINAL snapshot.
    /// Refused while an insertion is already in flight (exactly-once per attempt).
    public func insertExplicitly(sessionID: UUID) {
        var session: DictationSession?
        var isActive = false
        if activeSession?.id == sessionID { session = activeSession; isActive = true }
        else { session = retainedSessions.first { $0.id == sessionID } }
        guard var target = session,
              let text = target.transcript,
              target.phase == .resultReady || target.phase == .completed && target.insertionOutcome == nil
        else {
            diagnostics?("explicit insert refused: nothing to insert (phase=\(session?.phase.rawValue ?? "none"))")
            noticeMessage = "Nothing available to insert."
            return
        }
        guard target.isExternal, let original = target.externalDestination else {
            diagnostics?("explicit insert refused: no external destination on this session")
            noticeMessage = "This transcript has no external target. Use Copy."
            return
        }
        if target.phase == .inserting {
            noticeMessage = "Insertion already in progress."
            return
        }
        target.phase = .inserting
        target.insertionAttempted = true
        if isActive { activeSession = target }
        else if let index = retainedSessions.firstIndex(where: { $0.id == sessionID }) {
            retainedSessions[index] = target
        }

        let gen = generation
        Task { [weak self] in
            guard let self else { return }
            let check = DestinationPolicy.validate(original: original, current: self.destinations.currentSnapshot())
            guard self.generation == gen else { return }
            self.diagnostics?("explicit insert destination check: \(check)")
            let outcome: InsertionOutcome
            switch check {
            case .valid:
                let direct = await self.inserter.insertDirect(text: text, snapshot: original)
                guard self.generation == gen else { return }
                if InsertionOrchestrator.shouldAttemptFallback(after: direct) {
                    outcome = await self.inserter.insertViaPaste(text: text, snapshot: original)
                } else {
                    outcome = direct
                }
            case .stale(let reason), .unknown(let reason):
                outcome = .skippedStale(reason: reason)
            }
            guard self.generation == gen else { return }
            await self.applyExplicitInsertOutcome(sessionID: sessionID, outcome: outcome)
        }
    }

    private func applyExplicitInsertOutcome(sessionID: UUID, outcome: InsertionOutcome) {
        diagnostics?("explicit insert outcome: \(outcome)")
        if var active = activeSession, active.id == sessionID {
            active.insertionOutcome = outcome
            active.phase = isInserted(outcome) ? .completed : .resultReady
            activeSession = active
        } else if let index = retainedSessions.firstIndex(where: { $0.id == sessionID }) {
            retainedSessions[index].insertionOutcome = outcome
            retainedSessions[index].phase = isInserted(outcome) ? .completed : .resultReady
        }
    }

    // MARK: - Retention, discard, editor interplay

    /// Opening the transcript editor is an intentional focus change: preserve
    /// the pending result but invalidate automatic insertion.
    public func noteEditorOpened() {
        activeSession?.autoInsertInvalidated = true
        for i in retainedSessions.indices {
            retainedSessions[i].autoInsertInvalidated = true
        }
    }

    public func discardSession(id: UUID) {
        generation += 1
        if activeSession?.id == id {
            if let session = activeSession { cleanupFiles(for: session) }
            transcribeTask?.cancel()
            recorder?.cancel()
            recorder = nil
            isTranscribing = false
            activeSession = nil
            return
        }
        if let found = retainedSessions.first(where: { $0.id == id }) {
            cleanupFiles(for: found)
        }
        retainedSessions.removeAll { $0.id == id }
    }

    public func transcriptForCopy(sessionID: UUID) -> String? {
        if activeSession?.id == sessionID { return activeSession?.transcript }
        return retainedSessions.first { $0.id == sessionID }?.transcript
    }

    /// Apply a user edit to a reviewable transcript. Resets the insertion
    /// lifecycle so the edited text is what any later insert sends.
    public func updateTranscript(sessionID: UUID, text: String) {
        if var active = activeSession, active.id == sessionID, active.phase == .resultReady {
            active.transcript = text
            active.insertionOutcome = nil
            activeSession = active
        } else if let index = retainedSessions.firstIndex(where: { $0.id == sessionID }),
                  retainedSessions[index].phase == .resultReady {
            retainedSessions[index].transcript = text
            retainedSessions[index].insertionOutcome = nil
        }
    }

    public func postNotice(_ message: String) { noticeMessage = message }

    public func clearNotice() { noticeMessage = nil }

    private func pushRetained(_ session: DictationSession) {
        // Retained copies keep their retry audio; completed/inserted ones have none.
        retainedSessions.insert(session, at: 0)
        while retainedSessions.count > maxRetained {
            let dropped = retainedSessions.removeLast()
            cleanupFiles(for: dropped)
        }
    }

    private func cleanupFiles(for session: DictationSession) {
        tempStore.delete(session.captureURL)
        tempStore.delete(session.audioURL)
    }

    // MARK: - Device / duration / system events

    private func handleDurationTick(_ duration: TimeInterval) {
        recordingDuration = duration
        activeSession?.recordingDuration = duration
        if durationLimitSeconds > 0, duration >= durationLimitSeconds,
           activeSession?.phase == .recording {
            noticeMessage = "Recording stopped at the limit (\(AppSettings.clock(durationLimitSeconds)))."
            stopAndTranscribe()
        }
    }

    private func handleDeviceChange(_ detail: String) {
        guard let session = activeSession, session.phase == .recording else { return }
        recorder?.cancel()
        recorder = nil
        failActive(sessionID: session.id, message: "Input device changed (\(detail)). Recording stopped.", retryable: false)
    }

    /// System sleep / interruption: stop the mic, never insert.
    public func handleSystemSleep() {
        if let session = activeSession, session.phase == .recording || session.phase == .transcribing {
            noticeMessage = "Recording stopped because the Mac went to sleep."
            cancelActive()
        }
    }

    /// App termination: release the mic synchronously-best-effort.
    public func handleTermination() {
        transcribeTask?.cancel()
        recorder?.cancel()
        recorder = nil
    }
}
