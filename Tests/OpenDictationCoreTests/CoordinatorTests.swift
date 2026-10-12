import XCTest
@testable import OpenDictationCore
import OpenDictationTestSupport
import Foundation

// MARK: - Coordinator tests (fakes live in OpenDictationTestSupport)

// Note: the class itself is NOT @MainActor (XCTest setUp/tearDown overrides
// stay nonisolated); each test method is @MainActor and hops explicitly.
final class CoordinatorTests: XCTestCase {
    private var tempDir: URL!
    private var tempStore: TempAudioStore!
    private var captureFile: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        tempStore = TempAudioStore(directory: tempDir)
        captureFile = tempDir.appendingPathComponent("capture.caf")
        try! Data([0, 1, 2, 3]).write(to: captureFile)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    @MainActor private func makeCoordinator(
        settings: AppSettings = AppSettings(),
        provider: TranscriptionProvider? = nil,
        recorder: FakeRecorder? = nil,
        inserter: FakeInserter = FakeInserter(),
        destinations: FakeDestinations = FakeDestinations(),
        microphoneStatus: (() -> MicStatus)? = nil,
        requestMicrophone: (() async -> Bool)? = nil
    ) -> (SessionCoordinator, FakeRecorder, FakeInserter, FakeDestinations, StubConfigSource) {
        let rec = recorder ?? FakeRecorder(captureFile: captureFile)
        let source = StubConfigSource(settings: settings)
        let prov = provider ?? FakeProvider(script: .succeed(text: "hello world"))
        let micStatus: () -> MicStatus = microphoneStatus ?? { .authorized }
        let micRequest: () async -> Bool = requestMicrophone ?? { true }
        let coordinator = SessionCoordinator(
            makeRecorder: { rec },
            converter: FakeConverter(outputDir: tempDir),
            makeProvider: { prov },
            inserter: inserter,
            destinations: destinations,
            configSource: source,
            microphoneStatus: micStatus,
            requestMicrophone: micRequest,
            tempStore: tempStore
        )
        return (coordinator, rec, inserter, destinations, source)
    }

    @MainActor private func externalSnapshot() -> DestinationSnapshot {
        DestinationSnapshot(processID: 111, bundleIdentifier: "com.example.editor",
                            windowNumber: 1, focusedRole: "AXTextArea",
                            selectedText: "", selectionLocation: 0, selectionLength: 0)
    }

    @MainActor private func waitForPhase(
        _ coordinator: SessionCoordinator,
        _ phases: Set<SessionPhase>,
        timeout: TimeInterval = 5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let phase = coordinator.activeSession?.phase, phases.contains(phase) { return }
            if Date() > deadline {
                throw NSError(domain: "test", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "timed out waiting for \(phases); at \(String(describing: coordinator.activeSession?.phase))"])
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: Happy paths

    @MainActor func testExternalHappyPathInsertsExactlyOnce() async throws {
        let (coordinator, _, inserter, destinations, _) = makeCoordinator()
        let snap = externalSnapshot()
        destinations.captured = snap
        destinations.current = snap

        XCTAssertEqual(coordinator.startExternalSession(), .started)
        XCTAssertEqual(coordinator.activeSession?.phase, .recording)
        coordinator.stopAndTranscribe()
        try await waitForPhase(coordinator, [.completed])

        XCTAssertEqual(coordinator.activeSession?.transcript, "hello world")
        XCTAssertEqual(inserter.directCalls, 1)
        XCTAssertEqual(inserter.pasteCalls, 0) // no fallback after success
        XCTAssertEqual(inserter.lastText, "hello world")
        // Temp audio removed after success (no silent archives).
        XCTAssertNil(coordinator.activeSession?.audioURL)
    }

    @MainActor func testDoubleStopTranscribesOnce() async throws {
        let (coordinator, _, _, _, _) = makeCoordinator()
        let provider = FakeProvider(script: .succeed(text: "x"))
        _ = provider // (coordinator already holds its own; this documents single-flight)
        XCTAssertEqual(coordinator.startInAppSession(), .started)
        coordinator.stopAndTranscribe()
        coordinator.stopAndTranscribe() // second stop is a no-op
        try await waitForPhase(coordinator, [.resultReady])
        XCTAssertEqual(coordinator.activeSession?.transcript, "hello world")
    }

    @MainActor func testInAppSessionNeverInserts() async throws {
        let (coordinator, _, inserter, _, _) = makeCoordinator()
        XCTAssertEqual(coordinator.startInAppSession(), .started)
        coordinator.stopAndTranscribe()
        try await waitForPhase(coordinator, [.resultReady])
        XCTAssertEqual(inserter.directCalls, 0)
        XCTAssertEqual(inserter.pasteCalls, 0)
    }

    @MainActor func testStaleDestinationRefusesInsertionKeepsTranscript() async throws {
        let (coordinator, _, inserter, destinations, _) = makeCoordinator()
        destinations.captured = externalSnapshot()
        var moved = externalSnapshot()
        moved.selectionLocation = 99 // caret moved during transcription
        destinations.current = moved

        XCTAssertEqual(coordinator.startExternalSession(), .started)
        coordinator.stopAndTranscribe()
        try await waitForPhase(coordinator, [.resultReady])

        XCTAssertEqual(inserter.directCalls, 0)
        XCTAssertEqual(inserter.pasteCalls, 0)
        XCTAssertEqual(coordinator.activeSession?.transcript, "hello world")
        if case .skippedStale = coordinator.activeSession?.insertionOutcome { /* correct */ }
        else { XCTFail("expected skippedStale, got \(String(describing: coordinator.activeSession?.insertionOutcome))") }
    }

    // MARK: Insertion fallback discipline

    @MainActor func testUnsupportedFallsBackToPasteOnce() async throws {
        let (coordinator, _, inserter, destinations, _) = makeCoordinator()
        inserter.directOutcome = .unsupported(reason: "no AX support")
        inserter.pasteOutcome = .uncertain(reason: "paste sent")
        let snap = externalSnapshot()
        destinations.captured = snap
        destinations.current = snap

        XCTAssertEqual(coordinator.startExternalSession(), .started)
        coordinator.stopAndTranscribe()
        try await waitForPhase(coordinator, [.resultReady]) // uncertain: retained, not completed

        XCTAssertEqual(inserter.directCalls, 1)
        XCTAssertEqual(inserter.pasteCalls, 1)
        XCTAssertEqual(coordinator.activeSession?.insertionOutcome, .uncertain(reason: "paste sent"))
    }

    @MainActor func testUncertainDirectIsNeverFollowedByPaste() async throws {
        let (coordinator, _, inserter, destinations, _) = makeCoordinator()
        inserter.directOutcome = .uncertain(reason: "could not confirm")
        let snap = externalSnapshot()
        destinations.captured = snap
        destinations.current = snap

        XCTAssertEqual(coordinator.startExternalSession(), .started)
        coordinator.stopAndTranscribe()
        try await waitForPhase(coordinator, [.resultReady])

        XCTAssertEqual(inserter.directCalls, 1)
        XCTAssertEqual(inserter.pasteCalls, 0) // must not risk duplication
    }

    @MainActor func testConcurrentExplicitInsertAttemptsOnce() async throws {
        var settings = AppSettings()
        settings.insertionMode = .reviewOnly
        let (coordinator, _, inserter, destinations, _) = makeCoordinator(settings: settings)
        let snap = externalSnapshot()
        destinations.captured = snap
        destinations.current = snap

        XCTAssertEqual(coordinator.startExternalSession(), .started)
        coordinator.stopAndTranscribe()
        try await waitForPhase(coordinator, [.resultReady])
        XCTAssertEqual(inserter.directCalls, 0) // review mode: no auto-insert

        let id = coordinator.activeSession!.id
        coordinator.insertExplicitly(sessionID: id)
        coordinator.insertExplicitly(sessionID: id) // concurrent: refused while in flight
        try await waitForPhase(coordinator, [.completed])
        XCTAssertEqual(inserter.directCalls, 1)
    }

    // MARK: Cancellation and staleness

    @MainActor func testCancelDuringRecordingNeverTranscribes() async throws {
        let provider = FakeProvider(script: .succeed(text: "late"))
        let (coordinator, recorder, _, _, _) = makeCoordinator(provider: provider)
        XCTAssertEqual(coordinator.startInAppSession(), .started)
        coordinator.cancelActive()
        XCTAssertEqual(coordinator.activeSession?.phase, .canceled)
        XCTAssertTrue(recorder.cancelled)
        try await Task.sleep(nanoseconds: 100_000_000)
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 0)
        XCTAssertNil(coordinator.activeSession?.transcript)
    }

    @MainActor func testCancelDuringTranscriptionDropsLateResult() async throws {
        let provider = FakeProvider(script: .succeed(text: "late transcript"), delayNanoseconds: 300_000_000)
        let (coordinator, _, inserter, _, _) = makeCoordinator(provider: provider)
        XCTAssertEqual(coordinator.startInAppSession(), .started)
        coordinator.stopAndTranscribe()
        XCTAssertEqual(coordinator.activeSession?.phase, .transcribing)
        coordinator.cancelActive() // cancel while the request is in flight
        try await Task.sleep(nanoseconds: 600_000_000) // let the late response arrive
        XCTAssertEqual(coordinator.activeSession?.phase, .canceled)
        XCTAssertNil(coordinator.activeSession?.transcript)
        XCTAssertEqual(inserter.directCalls, 0)
        XCTAssertEqual(inserter.pasteCalls, 0)
    }

    @MainActor func testStaleResponseNeverReachesNewRecording() async throws {
        let provider = FakeProvider(script: .succeed(text: "session-one text"), delayNanoseconds: 300_000_000)
        let (coordinator, _, inserter, _, _) = makeCoordinator(provider: provider)
        XCTAssertEqual(coordinator.startInAppSession(), .started)
        coordinator.stopAndTranscribe()
        coordinator.cancelActive() // session one canceled while transcribing
        XCTAssertEqual(coordinator.startInAppSession(), .started) // session two begins
        XCTAssertEqual(coordinator.activeSession?.phase, .recording)
        try await Task.sleep(nanoseconds: 600_000_000) // session one's response arrives late
        XCTAssertEqual(coordinator.activeSession?.phase, .recording) // untouched
        XCTAssertNil(coordinator.activeSession?.transcript)
        XCTAssertEqual(inserter.directCalls + inserter.pasteCalls, 0)
    }

    @MainActor func testCancelIsIdempotent() async throws {
        let (coordinator, _, _, _, _) = makeCoordinator()
        XCTAssertEqual(coordinator.startInAppSession(), .started)
        coordinator.cancelActive()
        coordinator.cancelActive()
        XCTAssertEqual(coordinator.activeSession?.phase, .canceled)
    }

    // MARK: Failure, retry, cleanup

    @MainActor func testRetryableFailureKeepsAudioForExplicitRetry() async throws {
        let provider = FakeProvider(script: .succeedAfterFailures(
            text: "recovered", failures: 1, error: .server("HTTP 500")
        ))
        let (coordinator, _, _, _, _) = makeCoordinator(provider: provider)
        XCTAssertEqual(coordinator.startInAppSession(), .started)
        coordinator.stopAndTranscribe()
        try await waitForPhase(coordinator, [.failed])
        XCTAssertEqual(coordinator.activeSession?.retryable, true)
        let keptAudio = coordinator.activeSession?.audioURL
        XCTAssertNotNil(keptAudio)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptAudio!.path))

        coordinator.retry(sessionID: coordinator.activeSession!.id)
        try await waitForPhase(coordinator, [.resultReady])
        XCTAssertEqual(coordinator.activeSession?.transcript, "recovered")
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 2)
        // Audio removed after the successful retry.
        XCTAssertNil(coordinator.activeSession?.audioURL)
    }

    @MainActor func testTerminalFailureDeletesAudio() async throws {
        let provider = FakeProvider(script: .fail(.auth("bad token")))
        let (coordinator, _, _, _, _) = makeCoordinator(provider: provider)
        XCTAssertEqual(coordinator.startInAppSession(), .started)
        coordinator.stopAndTranscribe()
        try await waitForPhase(coordinator, [.failed])
        XCTAssertEqual(coordinator.activeSession?.retryable, false)
        XCTAssertNil(coordinator.activeSession?.audioURL)
    }

    @MainActor func testDiscardDeletesKeptAudio() async throws {
        let provider = FakeProvider(script: .fail(.timeout))
        let (coordinator, _, _, _, _) = makeCoordinator(provider: provider)
        XCTAssertEqual(coordinator.startInAppSession(), .started)
        coordinator.stopAndTranscribe()
        try await waitForPhase(coordinator, [.failed])
        let keptAudio = coordinator.activeSession?.audioURL
        XCTAssertNotNil(keptAudio)
        coordinator.discardSession(id: coordinator.activeSession!.id)
        XCTAssertNil(coordinator.activeSession)
        XCTAssertFalse(FileManager.default.fileExists(atPath: keptAudio!.path))
    }

    // MARK: Retention and editor interplay

    @MainActor func testNewRecordingRetainsUncommittedTranscript() async throws {
        var settings = AppSettings()
        settings.insertionMode = .reviewOnly
        let (coordinator, _, _, _, _) = makeCoordinator(settings: settings)
        XCTAssertEqual(coordinator.startInAppSession(), .started)
        coordinator.stopAndTranscribe()
        try await waitForPhase(coordinator, [.resultReady])

        XCTAssertEqual(coordinator.startInAppSession(), .started) // does not erase
        XCTAssertEqual(coordinator.retainedSessions.count, 1)
        XCTAssertEqual(coordinator.retainedSessions.first?.transcript, "hello world")
    }

    @MainActor func testEditorOpenedInvalidatesAutoInsert() async throws {
        let (coordinator, _, inserter, destinations, _) = makeCoordinator()
        let snap = externalSnapshot()
        destinations.captured = snap
        destinations.current = snap
        XCTAssertEqual(coordinator.startExternalSession(), .started)
        coordinator.noteEditorOpened()
        coordinator.stopAndTranscribe()
        try await waitForPhase(coordinator, [.resultReady])
        XCTAssertEqual(inserter.directCalls, 0)
        XCTAssertEqual(inserter.pasteCalls, 0)
        XCTAssertEqual(coordinator.activeSession?.transcript, "hello world")
    }

    @MainActor func testRecorderStartFailureDoesNotStickInRecording() {
        let recorder = FakeRecorder(captureFile: captureFile)
        recorder.startError = RecorderError.noInputDevice
        let (coordinator, _, _, _, _) = makeCoordinator(recorder: recorder)
        let result = coordinator.startInAppSession()
        if case .busy = result { /* correct */ }
        else { XCTFail("expected busy, got \(result)") }
        XCTAssertEqual(coordinator.activeSession?.phase, .failed)
        XCTAssertEqual(coordinator.activeSession?.retryable, false)
    }

    @MainActor func testInvalidEndpointBlocksStart() {
        var settings = AppSettings()
        settings.endpointURLString = "not a url"
        let (coordinator, _, _, _, _) = makeCoordinator(settings: settings)
        let result = coordinator.startInAppSession()
        if case .invalidEndpoint = result { /* correct */ }
        else { XCTFail("expected invalidEndpoint, got \(result)") }
        XCTAssertNil(coordinator.activeSession)
    }

    // MARK: Permission prompt, limits, device/sleep events, retained retry

    @MainActor func testMicPermissionPromptThenRecording() async throws {
        let status = Box<MicStatus>(.notDetermined)
        let (coordinator, _, _, _, _) = makeCoordinator(
            microphoneStatus: { status.value },
            requestMicrophone: { status.value = .authorized; return true }
        )
        XCTAssertEqual(coordinator.startInAppSession(), .started)
        XCTAssertEqual(coordinator.activeSession?.phase, .preparing)
        try await waitForPhase(coordinator, [.recording])
    }

    @MainActor func testMicPermissionDeniedFailsWithoutRecording() async throws {
        let status = Box<MicStatus>(.notDetermined)
        let (coordinator, recorder, _, _, _) = makeCoordinator(
            microphoneStatus: { status.value },
            requestMicrophone: { status.value = .denied; return false }
        )
        XCTAssertEqual(coordinator.startInAppSession(), .started)
        try await waitForPhase(coordinator, [.failed])
        XCTAssertEqual(coordinator.activeSession?.retryable, false)
        XCTAssertEqual(recorder.startCount, 0)
    }

    @MainActor func testDurationLimitStopsVisiblyAndTranscribes() async throws {
        var settings = AppSettings()
        settings.maxRecordingMinutes = 1
        let (coordinator, recorder, _, _, _) = makeCoordinator(settings: settings)
        XCTAssertEqual(coordinator.startInAppSession(), .started)
        recorder.onDuration?(59)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(coordinator.activeSession?.phase, .recording)
        recorder.onDuration?(60)
        try await waitForPhase(coordinator, [.transcribing, .resultReady])
        XCTAssertEqual(coordinator.noticeMessage?.hasPrefix("Recording stopped at the limit"), true)
        try await waitForPhase(coordinator, [.resultReady])
        XCTAssertEqual(coordinator.activeSession?.transcript, "hello world")
    }

    @MainActor func testUploadCapBoundsTheRecordingLimit() async throws {
        var settings = AppSettings()
        settings.maxRecordingMinutes = 15
        settings.maxUploadMB = 1
        XCTAssertEqual(settings.effectiveRecordingLimitSeconds, 32) // 1 MiB / 32 000 B/s
        XCTAssertEqual(AppSettings().effectiveRecordingLimitSeconds, 819) // defaults: 25 MiB caps 15 min
        let (coordinator, recorder, _, _, _) = makeCoordinator(settings: settings)
        XCTAssertEqual(coordinator.startInAppSession(), .started)
        recorder.onDuration?(31)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(coordinator.activeSession?.phase, .recording)
        recorder.onDuration?(32)
        try await waitForPhase(coordinator, [.transcribing, .resultReady])
        XCTAssertEqual(coordinator.noticeMessage?.contains("0:32"), true)
    }

    @MainActor func testDeviceChangeDuringRecordingStopsLoudly() async throws {
        let (coordinator, recorder, _, _, _) = makeCoordinator()
        XCTAssertEqual(coordinator.startInAppSession(), .started)
        recorder.onDeviceChange?("unplugged")
        try await waitForPhase(coordinator, [.failed])
        XCTAssertTrue(recorder.cancelled)
        XCTAssertEqual(coordinator.activeSession?.retryable, false)
        XCTAssertEqual(coordinator.activeSession?.errorMessage?.contains("Input device changed"), true)
    }

    @MainActor func testSystemSleepCancelsRecording() {
        let (coordinator, recorder, _, _, _) = makeCoordinator()
        XCTAssertEqual(coordinator.startInAppSession(), .started)
        coordinator.handleSystemSleep()
        XCTAssertEqual(coordinator.activeSession?.phase, .canceled)
        XCTAssertTrue(recorder.cancelled)
        XCTAssertNotNil(coordinator.noticeMessage)
    }

    @MainActor func testRetryFromRetainedSessionSwapsItBackToActive() async throws {
        var settings = AppSettings()
        settings.insertionMode = .reviewOnly
        let provider = FakeProvider(script: .succeedAfterFailures(text: "recovered", failures: 1, error: .timeout))
        let (coordinator, _, _, _, _) = makeCoordinator(settings: settings, provider: provider)
        XCTAssertEqual(coordinator.startInAppSession(), .started)
        coordinator.stopAndTranscribe()
        try await waitForPhase(coordinator, [.failed])
        let failedID = coordinator.activeSession!.id
        let keptAudio = try XCTUnwrap(coordinator.activeSession?.audioURL)

        XCTAssertEqual(coordinator.startInAppSession(), .started) // failed session moves to retained
        coordinator.stopAndTranscribe()
        try await waitForPhase(coordinator, [.resultReady])
        let secondID = coordinator.activeSession!.id
        XCTAssertEqual(coordinator.retainedSessions.map(\.id), [failedID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptAudio.path)) // still kept while retained

        coordinator.retry(sessionID: failedID)
        try await waitForPhase(coordinator, [.resultReady])
        XCTAssertEqual(coordinator.activeSession?.id, failedID)
        XCTAssertEqual(coordinator.activeSession?.transcript, "recovered")
        XCTAssertNil(coordinator.activeSession?.audioURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: keptAudio.path))
        XCTAssertEqual(coordinator.retainedSessions.map(\.id), [secondID]) // second result kept, not erased
    }
}
