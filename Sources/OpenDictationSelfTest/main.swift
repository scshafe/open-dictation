import Foundation
import OpenDictationCore
import OpenDictationTestSupport
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Dependency-free test runner (mirrors Tests/OpenDictationCoreTests)
//
// `swift test` (XCTest) is the canonical suite on Xcode hosts. This executable
// runs the same behavioral checks with a tiny harness so CLT-only hosts can
// still verify: `swift run OpenDictationSelfTest`. Exit code 1 on any failure.

var checkCount = 0
var failureCount = 0

func check(_ condition: Bool, _ message: String) {
    checkCount += 1
    if !condition {
        failureCount += 1
        print("FAIL: \(message)")
    }
}

func makeTempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Session transitions

func runTransitionTests() {
    check(SessionTransition.isAllowed(from: .idle, to: .preparing), "idle->preparing")
    check(SessionTransition.isAllowed(from: .preparing, to: .recording), "preparing->recording")
    check(SessionTransition.isAllowed(from: .recording, to: .transcribing), "recording->transcribing")
    check(SessionTransition.isAllowed(from: .transcribing, to: .resultReady), "transcribing->resultReady")
    check(SessionTransition.isAllowed(from: .resultReady, to: .inserting), "resultReady->inserting")
    check(SessionTransition.isAllowed(from: .inserting, to: .completed), "inserting->completed")
    check(SessionTransition.isAllowed(from: .recording, to: .canceled), "recording->canceled")
    check(SessionTransition.isAllowed(from: .transcribing, to: .canceled), "transcribing->canceled")
    check(SessionTransition.isAllowed(from: .failed, to: .transcribing), "failed->transcribing (retry)")
    check(SessionTransition.isAllowed(from: .inserting, to: .resultReady), "inserting->resultReady (retain)")
    check(!SessionTransition.isAllowed(from: .canceled, to: .transcribing), "canceled terminal")
    check(!SessionTransition.isAllowed(from: .canceled, to: .inserting), "canceled never inserts")
    check(!SessionTransition.isAllowed(from: .completed, to: .inserting), "completed terminal")
    check(!SessionTransition.isAllowed(from: .recording, to: .resultReady), "no pipeline skip")
    check(SessionTransition.isTerminal(phase: .failed, retryable: false), "failed terminal when not retryable")
    check(!SessionTransition.isTerminal(phase: .failed, retryable: true), "failed non-terminal when retryable")
}

// MARK: - Multipart

func runMultipartTests() {
    let config = ProviderConfig(
        endpointURL: URL(string: "http://127.0.0.1:8080/v1/audio/transcriptions")!,
        model: "m", bearerToken: "secret"
    )
    let audio = Data([0x52, 0x49, 0x46, 0x46])
    let (body, contentType) = MultipartRequestBuilder.buildBody(audioData: audio, config: config, boundary: "B")
    check(contentType == "multipart/form-data; boundary=B", "content type")
    let text = String(data: body, encoding: .utf8)!
    check(text.contains("name=\"file\"; filename=\"recording.wav\""), "file part")
    check(text.contains("Content-Type: audio/wav"), "audio mime")
    check(text.contains("name=\"model\""), "model present")
    check(body.range(of: audio) != nil, "audio bytes verbatim")
    check(body.suffix("--B--\r\n".utf8.count).elementsEqual(Data("--B--\r\n".utf8)), "closing boundary")

    var bare = config
    bare.model = nil
    bare.language = nil
    bare.bearerToken = nil
    let bareText = String(data: MultipartRequestBuilder.buildBody(audioData: Data([1]), config: bare, boundary: "B").body, encoding: .utf8)!
    check(!bareText.contains("name=\"model\""), "model omitted when empty")
    check(!bareText.contains("name=\"language\""), "language omitted when empty")
    let request = MultipartRequestBuilder.buildRequest(audioData: Data([1]), config: bare)
    check(request.value(forHTTPHeaderField: "Authorization") == nil, "auth omitted without token")
    check(request.url?.absoluteString == "http://127.0.0.1:8080/v1/audio/transcriptions", "exact URL, no appended path")
    check(!config.redactedDescription.contains("secret"), "redaction")
}

// MARK: - Provider responses

func runProviderResponseTests() {
    do {
        let result = try TranscriptResponseParser.parse(data: Data("{\"text\":\"Hi!\"}".utf8))
        check(result.text == "Hi!", "parse text verbatim")
    } catch {
        check(false, "parse should succeed: \(error)")
    }
    do {
        _ = try TranscriptResponseParser.parse(data: Data("{\"nope\":1}".utf8))
        check(false, "missing text must throw")
    } catch let error as ProviderError {
        check(error == .malformedResponse("missing 'text' field"), "missing text is malformed")
    } catch { check(false, "wrong error type") }
    do {
        _ = try TranscriptResponseParser.parse(data: Data("{\"text\":\"  \"}".utf8))
        check(false, "empty text must throw")
    } catch let error as ProviderError {
        check(error == .emptyTranscript, "empty text is emptyTranscript")
    } catch { check(false, "wrong error type") }

    check(HTTPStatusClassifier.error(statusCode: 401, bodyPrefix: nil) == .auth(""), "401 auth")
    check(HTTPStatusClassifier.error(statusCode: 429, bodyPrefix: nil) == .rateLimited, "429")
    check(HTTPStatusClassifier.error(statusCode: 500, bodyPrefix: nil) == .server("HTTP 500"), "500")
    for code in [301, 302, 307, 308] {
        if case .redirectBlocked = HTTPStatusClassifier.error(statusCode: code, bodyPrefix: nil) { check(true, "\(code) redirectBlocked") }
        else { check(false, "\(code) should be redirectBlocked") }
    }
    check(ProviderError.timeout.keepsAudioForRetry, "timeout retryable")
    check(!ProviderError.auth("x").keepsAudioForRetry, "auth terminal")
    check(!ProviderError.emptyTranscript.keepsAudioForRetry, "empty terminal")
}

// MARK: - WAV

func runWAVTests() {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    do {
        let url = dir.appendingPathComponent("tone.wav")
        let samples = WAVFile.sineSamples(sampleRate: 16000, seconds: 0.25)
        try WAVFile.writePCM16Mono(to: url, samples: samples, sampleRate: 16000)
        let info = try WAVFile.readInfo(from: url)
        check(info.sampleRate == 16000, "wav rate")
        check(info.channels == 1, "wav channels")
        check(info.bitsPerSample == 16, "wav bits")
        check(info.frames == samples.count, "wav frames")
        check(abs(info.durationSeconds - 0.25) < 0.001, "wav duration")
    } catch {
        check(false, "wav round trip failed: \(error)")
    }
    do {
        let bad = dir.appendingPathComponent("bad.wav")
        try Data("not a wav file at all, just text".utf8).write(to: bad)
        _ = try WAVFile.readInfo(from: bad)
        check(false, "invalid header must throw")
    } catch {
        check(true, "invalid header rejected")
    }
}

#if canImport(AVFoundation)
func runConversionTests() {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    do {
        // 44.1k mono fixture (non-integer ratio proves real resample).
        let source = dir.appendingPathComponent("capture.wav")
        try WAVFile.writePCM16Mono(
            to: source,
            samples: WAVFile.sineSamples(sampleRate: 44100, seconds: 0.1),
            sampleRate: 44100
        )
        let wavURL = try AudioFileConverter().convertToUploadWAV(source: source)
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let info = try WAVFile.readInfo(from: wavURL)
        check(info.sampleRate == 16000, "converted rate is 16k (resampled, not relabeled)")
        check(info.channels == 1, "converted mono")
        check(info.bitsPerSample == 16, "converted 16-bit")
        check(abs(info.durationSeconds - 0.1) < 0.01, "duration preserved by resample")
        check(abs(info.frames - 1600) <= 80, "frame count scaled (relabel would give 4410)")
    } catch {
        check(false, "conversion failed: \(error)")
    }
    do {
        let empty = dir.appendingPathComponent("empty.wav")
        try WAVFile.writePCM16Mono(to: empty, samples: [], sampleRate: 44100)
        _ = try AudioFileConverter().convertToUploadWAV(source: empty)
        check(false, "empty capture must throw")
    } catch {
        check(true, "empty capture rejected")
    }
}

func runBufferConvertTests() {
    let stereo = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 4)!
    buffer.frameLength = 4
    for i in 0..<4 {
        buffer.floatChannelData![0][i] = Float(i)
        buffer.floatChannelData![1][i] = Float(10 + i)
    }
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true)!
    if let converted = AudioBufferConvert.toInterleavedFloat32(buffer, target: target) {
        let abl = converted.audioBufferList.pointee
        let ptr = abl.mBuffers.mData!.assumingMemoryBound(to: Float.self)
        let values = Array(UnsafeBufferPointer(start: ptr, count: 8))
        check(values == [0, 10, 1, 11, 2, 12, 3, 13], "deinterleave exact")
    } else {
        check(false, "deinterleave failed")
    }
    let mono16 = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: false)!
    let b16 = AVAudioPCMBuffer(pcmFormat: mono16, frameCapacity: 2)!
    b16.frameLength = 2
    b16.int16ChannelData![0][0] = Int16.max
    b16.int16ChannelData![0][1] = 0
    let monoTarget = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: true)!
    if let converted = AudioBufferConvert.toInterleavedFloat32(b16, target: monoTarget) {
        let abl = converted.audioBufferList.pointee
        let ptr = abl.mBuffers.mData!.assumingMemoryBound(to: Float.self)
        check(abs(ptr[0] - 1.0) < 0.0001 && abs(ptr[1]) < 0.0001, "int16 normalize")
    } else {
        check(false, "int16 convert failed")
    }
    check(AudioBufferConvert.toInterleavedFloat32(buffer, target: monoTarget) == nil, "mismatched target refused")
}

/// Regression for the stereo-capture bug: the capture file's processing
/// format must be pinned to the interleaved buffer format for any channel
/// count, and writes above 4096 frames must be lossless.
func runCaptureFileTests() {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    for channels: AVAudioChannelCount in [1, 2] {
        do {
            let url = dir.appendingPathComponent("capture_\(channels).caf")
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: channels, interleaved: true)!
            var written = 0
            do { // scope: release the file before reopening
                let file = try AudioRecorder.makeCaptureFile(
                    url: url,
                    settings: AudioRecorder.captureSettings(sampleRate: 48000, channels: channels),
                    fileFormat: format
                )
                check(file.processingFormat == format, "capture processing format pinned (ch=\(channels))")
                for frames in [4096, 4800, 8192] as [AVAudioFrameCount] {
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
                    buffer.frameLength = frames
                    try file.write(from: buffer)
                    written += Int(frames)
                }
            }
            let reopened = try AVAudioFile(forReading: url)
            check(Int(reopened.length) == written, "capture writes lossless (ch=\(channels): \(reopened.length)/\(written))")
        } catch {
            check(false, "capture file failed (ch=\(channels)): \(error)")
        }
    }
}
#endif

// MARK: - Policies

func testSnapshot(
    pid: Int32 = 100, bundle: String? = "com.example.editor", window: Int? = 7,
    role: String? = "AXTextArea", identifier: String? = "doc-1",
    selectedText: String? = "", location: Int? = 5, length: Int? = 0,
    fingerprint: Int? = 42, secure: Bool = false
) -> DestinationSnapshot {
    DestinationSnapshot(processID: pid, bundleIdentifier: bundle, windowNumber: window,
                        focusedRole: role, focusedIdentifier: identifier, selectedText: selectedText,
                        selectionLocation: location, selectionLength: length,
                        valueFingerprint: fingerprint, isSecureField: secure)
}

func runPolicyTests() {
    check(DestinationPolicy.validate(original: testSnapshot(), current: testSnapshot()) == .valid, "unchanged valid")
    check(DestinationPolicy.validate(original: testSnapshot(), current: nil) != .valid, "nil current invalid")
    for (label, variant) in [
        ("pid", testSnapshot(pid: 200)),
        ("bundle", testSnapshot(bundle: "com.other")),
        ("window", testSnapshot(window: 8)),
        ("role", testSnapshot(role: "AXTextField")),
        ("caret", testSnapshot(location: 6)),
        ("selection", testSnapshot(length: 3)),
        ("seltext", testSnapshot(selectedText: "hi")),
        ("fingerprint", testSnapshot(fingerprint: 43)),
        ("secure", testSnapshot(secure: true))
    ] {
        let result = DestinationPolicy.validate(original: testSnapshot(), current: variant)
        if case .stale = result { check(true, "stale \(label)") }
        else { check(false, "expected stale for \(label), got \(result)") }
    }
    check(InsertionOrchestrator.shouldAttemptFallback(after: .unsupported(reason: "x")), "fallback after unsupported")
    check(!InsertionOrchestrator.shouldAttemptFallback(after: .uncertain(reason: "x")), "no fallback after uncertain")
    check(!InsertionOrchestrator.shouldAttemptFallback(after: .failed(reason: "x")), "no fallback after failed")
    check(!InsertionOrchestrator.shouldAttemptFallback(after: .inserted(method: "m")), "no fallback after success")
    check(ClipboardPolicy.shouldRestorePasteboard(changeCountAfterPaste: 10, currentChangeCount: 10), "restore when untouched")
    check(!ClipboardPolicy.shouldRestorePasteboard(changeCountAfterPaste: 10, currentChangeCount: 11), "no restore when changed")

    // Direct-write confirmation signals ("hi 👋" is 4 characters, 5 UTF-16 units).
    let text = "hi 👋"
    check(InsertionConfirmation.isConfirmed(insertedText: text, originalSelectionLocation: 5, echoedSelectedText: text, selectionAfter: nil, textAtInsertedRange: nil), "confirm via echoed selection")
    check(InsertionConfirmation.isConfirmed(insertedText: text, originalSelectionLocation: 5, echoedSelectedText: "", selectionAfter: nil, textAtInsertedRange: text), "confirm via string-for-range")
    check(InsertionConfirmation.isConfirmed(insertedText: text, originalSelectionLocation: 5, echoedSelectedText: "", selectionAfter: (location: 10, length: 0), textAtInsertedRange: nil), "confirm via caret after text (AppKit)")
    check(!InsertionConfirmation.isConfirmed(insertedText: text, originalSelectionLocation: 5, echoedSelectedText: "", selectionAfter: (location: 5, length: 0), textAtInsertedRange: "other"), "no confirm when caret unchanged")
    check(!InsertionConfirmation.isConfirmed(insertedText: text, originalSelectionLocation: 5, echoedSelectedText: nil, selectionAfter: (location: 10, length: 3), textAtInsertedRange: nil), "no confirm with non-empty selection")
    check(!InsertionConfirmation.isConfirmed(insertedText: text, originalSelectionLocation: nil, echoedSelectedText: nil, selectionAfter: (location: 10, length: 0), textAtInsertedRange: nil), "no confirm without start anchor")
    check(!InsertionConfirmation.isConfirmed(insertedText: "", originalSelectionLocation: 5, echoedSelectedText: "", selectionAfter: (location: 5, length: 0), textAtInsertedRange: ""), "empty text never confirms")
}

// MARK: - HTTP adapter

func runHTTPTests() async {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let audioURL = dir.appendingPathComponent("rec.wav")
    try! WAVFile.writePCM16Mono(to: audioURL, samples: WAVFile.sineSamples(sampleRate: 16000, seconds: 0.1), sampleRate: 16000)
    let config = ProviderConfig(endpointURL: URL(string: "http://127.0.0.1:9/x")!, model: "tiny", bearerToken: "tok")
    let adapter = HTTPTranscriptionAdapter(makeSession: { _ in
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: sessionConfig, delegate: RedirectGuardDelegate(), delegateQueue: nil)
    })

    StubURLProtocol.handler = { request in
        let okMethod = request.httpMethod == "POST"
        let okAuth = request.value(forHTTPHeaderField: "Authorization") == "Bearer tok"
        let okType = (request.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("multipart/form-data; boundary=")
        check(okMethod && okAuth && okType, "request contract (method/auth/multipart)")
        return StubURLProtocol.StubResponse(statusCode: 200, body: Data("{\"text\":\"hello\"}".utf8))
    }
    do {
        let result = try await adapter.transcribe(audioURL: audioURL, config: config)
        check(result.text == "hello", "adapter success text")
    } catch {
        check(false, "adapter success threw: \(error)")
    }

    let cases: [(Int, Data, ProviderError, String)] = [
        (401, Data("{\"error\":\"bad\"}".utf8), .auth("{\"error\":\"bad\"}"), "401 auth"),
        (429, Data(), .rateLimited, "429"),
        (500, Data("{\"text\":\"EVIL\"}".utf8), .server("{\"text\":\"EVIL\"}"), "500 server (body never transcript)"),
        (200, Data("nope".utf8), .malformedResponse("invalid JSON"), "malformed"),
        (200, Data("{\"text\":\" \"}".utf8), .emptyTranscript, "empty")
    ]
    for (status, body, expected, label) in cases {
        StubURLProtocol.handler = { _ in StubURLProtocol.StubResponse(statusCode: status, body: body) }
        do {
            _ = try await adapter.transcribe(audioURL: audioURL, config: config)
            check(false, "\(label) must throw")
        } catch let error as ProviderError {
            check(error == expected, "\(label) classification")
        } catch { check(false, "\(label) wrong error type") }
    }

    StubURLProtocol.handler = { _ in throw URLError(.timedOut) }
    do {
        _ = try await adapter.transcribe(audioURL: audioURL, config: config)
        check(false, "timeout must throw")
    } catch let error as ProviderError {
        check(error == .timeout, "timeout mapping")
    } catch { check(false, "timeout wrong error type") }

    var tiny = config
    tiny.maxUploadBytes = 10
    StubURLProtocol.handler = { _ in
        check(false, "oversize request must not be sent")
        return StubURLProtocol.StubResponse(statusCode: 200, body: Data())
    }
    do {
        _ = try await adapter.transcribe(audioURL: audioURL, config: tiny)
        check(false, "oversize must throw")
    } catch let error as ProviderError {
        if case .uploadTooLarge = error { check(true, "size guard") }
        else { check(false, "wrong oversize error") }
    } catch { check(false, "oversize wrong error type") }

    // Refused cross-origin redirect: the 3xx reaches the adapter -> redirectBlocked.
    StubURLProtocol.handler = { _ in StubURLProtocol.StubResponse(statusCode: 302, body: Data()) }
    do {
        _ = try await adapter.transcribe(audioURL: audioURL, config: config)
        check(false, "302 must throw")
    } catch let error as ProviderError {
        if case .redirectBlocked = error { check(true, "3xx surfaces as redirectBlocked") }
        else { check(false, "3xx wrong classification: \(error)") }
    } catch { check(false, "3xx wrong error type") }

    // Origin comparison includes the effective port.
    let base = URL(string: "http://127.0.0.1:8080/v1")!
    check(RedirectGuardDelegate.isSameOrigin(base, URL(string: "http://127.0.0.1:8080/other")), "same origin: same port")
    check(!RedirectGuardDelegate.isSameOrigin(base, URL(string: "http://127.0.0.1:9999/other")), "different port is a different origin")
    check(RedirectGuardDelegate.isSameOrigin(URL(string: "https://ASR.example.com/a"), URL(string: "https://asr.example.com:443/b")), "default port equals explicit; host case-insensitive")
    check(!RedirectGuardDelegate.isSameOrigin(URL(string: "https://asr.example.com/a"), URL(string: "http://asr.example.com/a")), "scheme change is a different origin")
    check(!RedirectGuardDelegate.isSameOrigin(base, nil), "missing URL is never same origin")
}

// MARK: - Coordinator

@MainActor
func waitForPhase(_ coordinator: SessionCoordinator, _ phases: Set<SessionPhase>, label: String) async -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while true {
        if let phase = coordinator.activeSession?.phase, phases.contains(phase) { return true }
        if Date() > deadline {
            check(false, "\(label): timed out at \(String(describing: coordinator.activeSession?.phase))")
            return false
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

struct Harness {
    let dir: URL
    let store: TempAudioStore
    let captureFile: URL
    let recorder: FakeRecorder
    let inserter: FakeInserter
    let destinations: FakeDestinations
    let source: StubConfigSource
    let coordinator: SessionCoordinator

    @MainActor
    init(
        settings: AppSettings = AppSettings(),
        provider: TranscriptionProvider? = nil,
        startError: Error? = nil,
        microphoneStatus: (() -> MicStatus)? = nil,
        requestMicrophone: (() async -> Bool)? = nil
    ) {
        let micStatus: () -> MicStatus = microphoneStatus ?? { .authorized }
        let micRequest: () async -> Bool = requestMicrophone ?? { true }
        dir = makeTempDir()
        store = TempAudioStore(directory: dir)
        captureFile = dir.appendingPathComponent("capture.caf")
        try! Data([0, 1, 2, 3]).write(to: captureFile)
        let rec = FakeRecorder(captureFile: captureFile)
        rec.startError = startError
        recorder = rec
        inserter = FakeInserter()
        destinations = FakeDestinations()
        source = StubConfigSource(settings: settings)
        let prov = provider ?? FakeProvider(script: .succeed(text: "hello world"))
        let outputDir = dir
        coordinator = SessionCoordinator(
            makeRecorder: { rec },
            converter: FakeConverter(outputDir: outputDir),
            makeProvider: { prov },
            inserter: inserter,
            destinations: destinations,
            configSource: source,
            microphoneStatus: micStatus,
            requestMicrophone: micRequest,
            tempStore: store
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: dir)
    }
}

func externalSnapshot() -> DestinationSnapshot {
    DestinationSnapshot(processID: 111, bundleIdentifier: "com.example.editor", windowNumber: 1,
                        focusedRole: "AXTextArea", selectedText: "", selectionLocation: 0, selectionLength: 0)
}

@MainActor
func runCoordinatorTests() async {
    // Happy path: exactly-once insert, audio cleaned up.
    do {
        let h = Harness()
        defer { h.cleanup() }
        let snap = externalSnapshot()
        h.destinations.captured = snap
        h.destinations.current = snap
        check(h.coordinator.startExternalSession() == .started, "external start")
        h.coordinator.stopAndTranscribe()
        if await waitForPhase(h.coordinator, [.completed], label: "happy path") {
            check(h.coordinator.activeSession?.transcript == "hello world", "happy transcript")
            check(h.inserter.directCalls == 1 && h.inserter.pasteCalls == 0, "exactly-once, no fallback")
            check(h.coordinator.activeSession?.audioURL == nil, "audio cleaned after success")
        }
    }
    // Double-stop: single transcription.
    do {
        let h = Harness()
        defer { h.cleanup() }
        check(h.coordinator.startInAppSession() == .started, "in-app start")
        h.coordinator.stopAndTranscribe()
        h.coordinator.stopAndTranscribe()
        if await waitForPhase(h.coordinator, [.resultReady], label: "double stop") {
            check(h.coordinator.activeSession?.transcript == "hello world", "double-stop single result")
        }
    }
    // In-app never inserts.
    do {
        let h = Harness()
        defer { h.cleanup() }
        _ = h.coordinator.startInAppSession()
        h.coordinator.stopAndTranscribe()
        if await waitForPhase(h.coordinator, [.resultReady], label: "in-app") {
            check(h.inserter.directCalls + h.inserter.pasteCalls == 0, "in-app never inserts")
        }
    }
    // Stale destination refuses, keeps transcript.
    do {
        let h = Harness()
        defer { h.cleanup() }
        h.destinations.captured = externalSnapshot()
        var moved = externalSnapshot()
        moved.selectionLocation = 99
        h.destinations.current = moved
        _ = h.coordinator.startExternalSession()
        h.coordinator.stopAndTranscribe()
        if await waitForPhase(h.coordinator, [.resultReady], label: "stale") {
            check(h.inserter.directCalls + h.inserter.pasteCalls == 0, "stale: no insert")
            check(h.coordinator.activeSession?.transcript == "hello world", "stale: transcript kept")
            if case .skippedStale = h.coordinator.activeSession?.insertionOutcome {
                check(true, "stale outcome")
            } else { check(false, "expected skippedStale") }
        }
    }
    // Unsupported -> exactly one paste; uncertain direct -> no paste.
    do {
        let h = Harness()
        defer { h.cleanup() }
        h.inserter.directOutcome = .unsupported(reason: "x")
        h.inserter.pasteOutcome = .uncertain(reason: "paste sent")
        let snap = externalSnapshot()
        h.destinations.captured = snap
        h.destinations.current = snap
        _ = h.coordinator.startExternalSession()
        h.coordinator.stopAndTranscribe()
        if await waitForPhase(h.coordinator, [.resultReady], label: "fallback") {
            check(h.inserter.directCalls == 1 && h.inserter.pasteCalls == 1, "one fallback paste")
        }
    }
    do {
        let h = Harness()
        defer { h.cleanup() }
        h.inserter.directOutcome = .uncertain(reason: "x")
        let snap = externalSnapshot()
        h.destinations.captured = snap
        h.destinations.current = snap
        _ = h.coordinator.startExternalSession()
        h.coordinator.stopAndTranscribe()
        if await waitForPhase(h.coordinator, [.resultReady], label: "uncertain") {
            check(h.inserter.directCalls == 1 && h.inserter.pasteCalls == 0, "no paste after uncertain")
        }
    }
    // Concurrent explicit inserts attempt once.
    do {
        var settings = AppSettings()
        settings.insertionMode = .reviewOnly
        let h = Harness(settings: settings)
        defer { h.cleanup() }
        let snap = externalSnapshot()
        h.destinations.captured = snap
        h.destinations.current = snap
        _ = h.coordinator.startExternalSession()
        h.coordinator.stopAndTranscribe()
        if await waitForPhase(h.coordinator, [.resultReady], label: "review mode") {
            check(h.inserter.directCalls == 0, "review mode: no auto-insert")
            let id = h.coordinator.activeSession!.id
            h.coordinator.insertExplicitly(sessionID: id)
            h.coordinator.insertExplicitly(sessionID: id)
            if await waitForPhase(h.coordinator, [.completed], label: "explicit insert") {
                check(h.inserter.directCalls == 1, "concurrent explicit inserts attempt once")
            }
        }
    }
    // Cancel during recording: no transcription.
    do {
        let provider = FakeProvider(script: .succeed(text: "late"))
        let h = Harness(provider: provider)
        defer { h.cleanup() }
        _ = h.coordinator.startInAppSession()
        h.coordinator.cancelActive()
        check(h.coordinator.activeSession?.phase == .canceled, "cancel phase")
        check(h.recorder.cancelled, "recorder cancelled")
        try? await Task.sleep(nanoseconds: 100_000_000)
        check((await provider.requests).count == 0, "cancel before stop: no request")
    }
    // Cancel during transcription drops the late result.
    do {
        let provider = FakeProvider(script: .succeed(text: "late"), delayNanoseconds: 300_000_000)
        let h = Harness(provider: provider)
        defer { h.cleanup() }
        _ = h.coordinator.startInAppSession()
        h.coordinator.stopAndTranscribe()
        h.coordinator.cancelActive()
        try? await Task.sleep(nanoseconds: 600_000_000)
        check(h.coordinator.activeSession?.phase == .canceled, "cancel during transcription stays canceled")
        check(h.coordinator.activeSession?.transcript == nil, "late result dropped")
        check(h.inserter.directCalls + h.inserter.pasteCalls == 0, "canceled never inserts")
    }
    // Stale response never reaches a new recording.
    do {
        let provider = FakeProvider(script: .succeed(text: "one"), delayNanoseconds: 300_000_000)
        let h = Harness(provider: provider)
        defer { h.cleanup() }
        _ = h.coordinator.startInAppSession()
        h.coordinator.stopAndTranscribe()
        h.coordinator.cancelActive()
        let secondResult = h.coordinator.startInAppSession()
        check(secondResult == .started, "second session starts (got \(secondResult), phase \(String(describing: h.coordinator.activeSession?.phase)))")
        try? await Task.sleep(nanoseconds: 600_000_000)
        check(h.coordinator.activeSession?.phase == .recording, "new recording untouched by stale response")
        check(h.coordinator.activeSession?.transcript == nil, "no stale transcript")
    }
    // Retryable failure keeps audio; retry succeeds; audio then removed.
    do {
        let provider = FakeProvider(script: .succeedAfterFailures(text: "recovered", failures: 1, error: .server("500")))
        let h = Harness(provider: provider)
        defer { h.cleanup() }
        _ = h.coordinator.startInAppSession()
        h.coordinator.stopAndTranscribe()
        if await waitForPhase(h.coordinator, [.failed], label: "retryable fail") {
            check(h.coordinator.activeSession?.retryable == true, "server error retryable")
            let kept = h.coordinator.activeSession?.audioURL
            check(kept != nil && FileManager.default.fileExists(atPath: kept!.path), "audio kept for retry")
            h.coordinator.retry(sessionID: h.coordinator.activeSession!.id)
            if await waitForPhase(h.coordinator, [.resultReady], label: "retry") {
                check(h.coordinator.activeSession?.transcript == "recovered", "retry transcript")
                check((await provider.requests).count == 2, "two attempts total")
                check(h.coordinator.activeSession?.audioURL == nil, "audio removed after success")
            }
        }
    }
    // Terminal failure deletes audio.
    do {
        let provider = FakeProvider(script: .fail(.auth("bad")))
        let h = Harness(provider: provider)
        defer { h.cleanup() }
        _ = h.coordinator.startInAppSession()
        h.coordinator.stopAndTranscribe()
        if await waitForPhase(h.coordinator, [.failed], label: "terminal fail") {
            check(h.coordinator.activeSession?.retryable == false, "auth terminal")
            check(h.coordinator.activeSession?.audioURL == nil, "terminal failure deletes audio")
        }
    }
    // Discard deletes kept audio.
    do {
        let provider = FakeProvider(script: .fail(.timeout))
        let h = Harness(provider: provider)
        defer { h.cleanup() }
        _ = h.coordinator.startInAppSession()
        h.coordinator.stopAndTranscribe()
        if await waitForPhase(h.coordinator, [.failed], label: "discard setup") {
            let kept = h.coordinator.activeSession?.audioURL
            h.coordinator.discardSession(id: h.coordinator.activeSession!.id)
            check(h.coordinator.activeSession == nil, "discarded")
            check(!FileManager.default.fileExists(atPath: kept!.path), "discard deletes audio")
        }
    }
    // New recording retains uncommitted transcript.
    do {
        var settings = AppSettings()
        settings.insertionMode = .reviewOnly
        let h = Harness(settings: settings)
        defer { h.cleanup() }
        _ = h.coordinator.startInAppSession()
        h.coordinator.stopAndTranscribe()
        if await waitForPhase(h.coordinator, [.resultReady], label: "retain setup") {
            check(h.coordinator.startInAppSession() == .started, "second start ok")
            check(h.coordinator.retainedSessions.count == 1, "uncommitted retained")
            check(h.coordinator.retainedSessions.first?.transcript == "hello world", "retained text intact")
        }
    }
    // Editor opened invalidates auto-insert.
    do {
        let h = Harness()
        defer { h.cleanup() }
        let snap = externalSnapshot()
        h.destinations.captured = snap
        h.destinations.current = snap
        _ = h.coordinator.startExternalSession()
        h.coordinator.noteEditorOpened()
        h.coordinator.stopAndTranscribe()
        if await waitForPhase(h.coordinator, [.resultReady], label: "editor invalidate") {
            check(h.inserter.directCalls + h.inserter.pasteCalls == 0, "editor open blocks auto-insert")
        }
    }
    // Recorder start failure: failed, not stuck in recording.
    do {
        let h = Harness(startError: RecorderError.noInputDevice)
        defer { h.cleanup() }
        let result = h.coordinator.startInAppSession()
        if case .busy = result { check(true, "recorder failure returns busy") }
        else { check(false, "recorder failure should return busy") }
        check(h.coordinator.activeSession?.phase == .failed, "failed phase, not recording")
    }
    // Invalid endpoint blocks start.
    do {
        var settings = AppSettings()
        settings.endpointURLString = "not a url"
        let h = Harness(settings: settings)
        defer { h.cleanup() }
        let result = h.coordinator.startInAppSession()
        if case .invalidEndpoint = result { check(true, "invalid endpoint blocked") }
        else { check(false, "invalid endpoint should block") }
        check(h.coordinator.activeSession == nil, "no session on invalid endpoint")
    }
    // Mic permission prompt (not determined -> granted) -> recording.
    do {
        let status = Box<MicStatus>(.notDetermined)
        let h = Harness(microphoneStatus: { status.value }, requestMicrophone: { status.value = .authorized; return true })
        defer { h.cleanup() }
        check(h.coordinator.startInAppSession() == .started, "permission prompt path starts")
        check(h.coordinator.activeSession?.phase == .preparing, "preparing while prompting")
        _ = await waitForPhase(h.coordinator, [.recording], label: "permission granted")
    }
    // Mic permission denied -> failed, recorder never started.
    do {
        let status = Box<MicStatus>(.notDetermined)
        let h = Harness(microphoneStatus: { status.value }, requestMicrophone: { status.value = .denied; return false })
        defer { h.cleanup() }
        _ = h.coordinator.startInAppSession()
        if await waitForPhase(h.coordinator, [.failed], label: "permission denied") {
            check(h.coordinator.activeSession?.retryable == false, "denied not retryable")
            check(h.recorder.startCount == 0, "denied never starts recorder")
        }
    }
    // Duration limit: visible stop with a notice, then transcription.
    do {
        var settings = AppSettings()
        settings.maxRecordingMinutes = 1
        let h = Harness(settings: settings)
        defer { h.cleanup() }
        _ = h.coordinator.startInAppSession()
        h.recorder.onDuration?(59)
        try? await Task.sleep(nanoseconds: 50_000_000)
        check(h.coordinator.activeSession?.phase == .recording, "below limit keeps recording")
        h.recorder.onDuration?(60)
        if await waitForPhase(h.coordinator, [.transcribing, .resultReady], label: "limit stop") {
            check(h.coordinator.noticeMessage?.hasPrefix("Recording stopped at the limit") == true, "limit notice")
            if await waitForPhase(h.coordinator, [.resultReady], label: "limit transcribe") {
                check(h.coordinator.activeSession?.transcript == "hello world", "limit still transcribes")
            }
        }
    }
    // Upload size caps the recording limit so a recording can never be unuploadable.
    do {
        var settings = AppSettings()
        settings.maxRecordingMinutes = 15
        settings.maxUploadMB = 1
        check(settings.effectiveRecordingLimitSeconds == 32, "1 MiB upload cap -> 32 s limit (got \(settings.effectiveRecordingLimitSeconds))")
        check(AppSettings().effectiveRecordingLimitSeconds == 819, "defaults: 25 MiB caps 15 min to 819 s (got \(AppSettings().effectiveRecordingLimitSeconds))")
        let h = Harness(settings: settings)
        defer { h.cleanup() }
        _ = h.coordinator.startInAppSession()
        h.recorder.onDuration?(31)
        try? await Task.sleep(nanoseconds: 50_000_000)
        check(h.coordinator.activeSession?.phase == .recording, "below upload-capped limit keeps recording")
        h.recorder.onDuration?(32)
        if await waitForPhase(h.coordinator, [.transcribing, .resultReady], label: "upload-capped limit stop") {
            check(h.coordinator.noticeMessage?.contains("0:32") == true, "limit notice shows effective m:ss")
        }
    }
    // Device change during recording: loud stop, not retryable.
    do {
        let h = Harness()
        defer { h.cleanup() }
        _ = h.coordinator.startInAppSession()
        h.recorder.onDeviceChange?("unplugged")
        if await waitForPhase(h.coordinator, [.failed], label: "device change") {
            check(h.recorder.cancelled, "device change releases mic")
            check(h.coordinator.activeSession?.retryable == false, "device change not retryable")
            check(h.coordinator.activeSession?.errorMessage?.contains("Input device changed") == true, "device change message")
        }
    }
    // System sleep cancels the recording and releases the mic.
    do {
        let h = Harness()
        defer { h.cleanup() }
        _ = h.coordinator.startInAppSession()
        h.coordinator.handleSystemSleep()
        check(h.coordinator.activeSession?.phase == .canceled, "sleep cancels")
        check(h.recorder.cancelled, "sleep releases mic")
        check(h.coordinator.noticeMessage != nil, "sleep notice")
    }
    // Retry from a retained (kept) session swaps it back to active.
    do {
        var settings = AppSettings()
        settings.insertionMode = .reviewOnly
        let provider = FakeProvider(script: .succeedAfterFailures(text: "recovered", failures: 1, error: .timeout))
        let h = Harness(settings: settings, provider: provider)
        defer { h.cleanup() }
        _ = h.coordinator.startInAppSession()
        h.coordinator.stopAndTranscribe()
        if await waitForPhase(h.coordinator, [.failed], label: "retained retry setup") {
            let failedID = h.coordinator.activeSession!.id
            let kept = h.coordinator.activeSession?.audioURL
            _ = h.coordinator.startInAppSession()
            h.coordinator.stopAndTranscribe()
            if await waitForPhase(h.coordinator, [.resultReady], label: "second session") {
                let secondID = h.coordinator.activeSession!.id
                check(h.coordinator.retainedSessions.map(\.id) == [failedID], "failed session retained")
                check(kept != nil && FileManager.default.fileExists(atPath: kept!.path), "retained keeps retry audio")
                h.coordinator.retry(sessionID: failedID)
                if await waitForPhase(h.coordinator, [.resultReady], label: "retained retry") {
                    check(h.coordinator.activeSession?.id == failedID, "retried session is active")
                    check(h.coordinator.activeSession?.transcript == "recovered", "retained retry transcript")
                    check(h.coordinator.activeSession?.audioURL == nil && !FileManager.default.fileExists(atPath: kept!.path), "retry audio removed")
                    check(h.coordinator.retainedSessions.map(\.id) == [secondID], "second session kept, not erased")
                }
            }
        }
    }
}

// MARK: - Live integration (real adapter -> real mock server, opt-in)

/// Usage: start the mock (`./scripts/run-mock-server.sh --port 8080`), then:
/// `swift run OpenDictationSelfTest --live-mock http://127.0.0.1:8080`
func runLiveMockTest(base rawBase: String) async {
    let base = rawBase.hasSuffix("/") ? String(rawBase.dropLast()) : rawBase
    guard let url = URL(string: base + "/v1/audio/transcriptions") else {
        check(false, "live-mock: bad base URL")
        return
    }
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let audioURL = dir.appendingPathComponent("live.wav")
    do {
        try WAVFile.writePCM16Mono(
            to: audioURL,
            samples: WAVFile.sineSamples(sampleRate: 16000, seconds: 0.5),
            sampleRate: 16000
        )
        let config = ProviderConfig(endpointURL: url, model: "live-probe")
        let result = try await HTTPTranscriptionAdapter().transcribe(audioURL: audioURL, config: config)
        check(result.text.contains("MOCK TRANSCRIPT"), "live-mock: mock text returned (\(result.text.prefix(80)))")
        check(result.text.contains("live-probe"), "live-mock: model field received by server")
    } catch {
        check(false, "live-mock: request failed: \(error)")
    }
}

// MARK: - Live endpoint (real adapter -> a REAL transcription server, opt-in)
//
// Usage: swift run OpenDictationSelfTest --live-endpoint <URL|app> --clip <wav> [--language en]
//   URL    full transcription URL (generous 300 s / 900 s timeouts), or `app`
//          to load endpoint, model, language and timeouts from the app's saved
//          Settings (preferences domain com.example.opendictation).
//   --clip a short NON-SENSITIVE speech WAV, e.g. generated with `say`.
// The bearer token is read from the app's Keychain entry — never from
// arguments, the environment, or stdin — and is never printed. Only the
// transcript and the classified error are shown, so this verifies
// authentication and end-to-end recognition without exposing credentials.
func runLiveEndpointTest(arguments: [String]) async {
    let target = arguments.first ?? "app"
    var clipPath: String?
    var languageOverride: String?
    var i = 1
    while i < arguments.count {
        switch arguments[i] {
        case "--clip": if i + 1 < arguments.count { clipPath = arguments[i + 1]; i += 1 }
        case "--language": if i + 1 < arguments.count { languageOverride = arguments[i + 1]; i += 1 }
        default: break
        }
        i += 1
    }
    var settings: AppSettings
    if target == "app" {
        guard let defaults = UserDefaults(suiteName: "com.example.opendictation") else {
            check(false, "live-endpoint: cannot open the app's preferences domain")
            return
        }
        settings = SettingsStore(defaults: defaults).load()
    } else {
        settings = AppSettings(endpointURLString: target, requestTimeout: 300, resourceTimeout: 900)
    }
    if let languageOverride { settings.language = languageOverride }
    let token = KeychainTokenStore().loadToken()
    print("live-endpoint: token \(token == nil ? "ABSENT — save it in the app's Settings → Bearer token" : "present (read from Keychain, not shown)")")
    guard let config = settings.providerConfig(bearerToken: token) else {
        check(false, "live-endpoint: invalid endpoint URL '\(settings.endpointURLString)'")
        return
    }
    print("live-endpoint: \(config.redactedDescription) timeouts=\(Int(config.requestTimeout))s/\(Int(config.resourceTimeout))s")
    guard let clipPath else {
        check(false, "live-endpoint: --clip <wav> is required (a real recognizer returns nothing for a tone)")
        return
    }
    let clipURL = URL(fileURLWithPath: clipPath)
    do {
        let info = try WAVFile.readInfo(from: clipURL)
        print("live-endpoint: clip \(info.channels)ch \(info.sampleRate)Hz \(info.bitsPerSample)-bit \(String(format: "%.2f", info.durationSeconds))s")
    } catch {
        check(false, "live-endpoint: clip is not a readable WAV: \(error)")
        return
    }
    let started = Date()
    do {
        let result = try await HTTPTranscriptionAdapter().transcribe(audioURL: clipURL, config: config)
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
        print("live-endpoint: transcript after \(elapsed)s: “\(result.text)”")
        check(!result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "live-endpoint: non-empty transcript")
    } catch let error as ProviderError {
        check(false, "live-endpoint: \(error.userMessage) [\(error)]")
    } catch {
        check(false, "live-endpoint: \(error)")
    }
}

// MARK: - Entry

@main
struct SelfTest {
    static func main() async {
        if let index = CommandLine.arguments.firstIndex(of: "--live-endpoint") {
            await runLiveEndpointTest(arguments: Array(CommandLine.arguments[(index + 1)...]))
            print("selftest-endpoint: \(checkCount) checks, \(failureCount) failures")
            if failureCount > 0 { Foundation.exit(1) }
            return
        }
        if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--live-mock" {
            await runLiveMockTest(base: CommandLine.arguments[2])
            print("selftest-live: \(checkCount) checks, \(failureCount) failures")
            if failureCount > 0 { Foundation.exit(1) }
            return
        }
        runTransitionTests()
        runMultipartTests()
        runProviderResponseTests()
        runWAVTests()
        #if canImport(AVFoundation)
        runConversionTests()
        runBufferConvertTests()
        runCaptureFileTests()
        #endif
        runPolicyTests()
        await runHTTPTests()
        await runCoordinatorTests()
        print("selftest: \(checkCount) checks, \(failureCount) failures")
        if failureCount > 0 {
            Foundation.exit(1)
        }
    }
}
