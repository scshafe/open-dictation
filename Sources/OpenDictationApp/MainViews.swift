import AppKit
import OpenDictationCore
import SwiftUI

// MARK: - Main window

struct MainView: View {
    @ObservedObject private var context = AppContext.shared
    // Session state lives in the coordinator, a separate ObservableObject:
    // observe it directly, or phase changes never redraw this view.
    @ObservedObject private var coordinator = AppContext.shared.coordinator
    @Environment(\.openWindow) private var openWindow
    /// Reopen on the tab that was last in use (ordinary preference, no secrets).
    @AppStorage("OpenDictation.mainTab") private var selectedTab = "dictate"

    var body: some View {
        TabView(selection: $selectedTab) {
            TranscriptTab()
                .tabItem { Label("Dictate", systemImage: "mic") }
                .tag("dictate")
            SettingsTab()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag("settings")
            PermissionsTab()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag("permissions")
        }
        .frame(minWidth: 560, minHeight: 480)
        .navigationTitle(windowTitle)
        .onAppear {
            // Opening the window for editing invalidates pending auto-insert.
            context.coordinator.noteEditorOpened()
        }
    }

    /// The window title (Dock, Cmd-Tab, title bar) also names the live state.
    private var windowTitle: String {
        switch coordinator.activeSession?.phase {
        case .recording: return "Open Dictation — Recording"
        case .transcribing: return "Open Dictation — Transcribing"
        default: return "Open Dictation"
        }
    }
}

// MARK: - Transcript tab

private struct TranscriptTab: View {
    @ObservedObject private var context = AppContext.shared
    /// Observed directly: `context` only publishes settings/token changes, so
    /// reading `context.coordinator` here would leave the tab frozen while
    /// recording (the bug behind "Record never shows it started").
    @ObservedObject private var coordinator = AppContext.shared.coordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editBuffer: String = ""
    @State private var editingSessionID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            stateStrip
            if isRecording {
                VStack(alignment: .leading, spacing: 4) {
                    LevelMeterView(level: coordinator.micLevel)
                        .accessibilityLabel("Microphone level")
                    Text("Microphone level").font(.caption).foregroundStyle(.secondary)
                }
            }
            statusBanner
            recordControls
            transcriptEditor
            retainedList
            Spacer()
        }
        .padding(16)
        .onChange(of: coordinator.activeSession?.transcript) { _, _ in syncEditor() }
        .onChange(of: coordinator.activeSession?.id) { _, _ in syncEditor() }
        .onAppear { syncEditor() }
    }

    private var phase: SessionPhase? { coordinator.activeSession?.phase }
    private var isRecording: Bool { phase == .recording }
    private var isLive: Bool {
        switch phase {
        case .preparing, .recording, .transcribing, .inserting: return true
        default: return false
        }
    }
    private var activeTranscript: String? { coordinator.activeSession?.transcript }

    // MARK: State strip — the title text always names the state (never color-only)

    private var stateTitle: String {
        switch phase {
        case .preparing: return "Preparing…"
        case .recording: return "Recording"
        case .transcribing: return "Transcribing…"
        case .inserting: return "Inserting…"
        case .resultReady: return "Transcript ready"
        case .failed: return "Dictation failed"
        case .completed: return "Done"
        case .canceled: return "Canceled"
        case .idle, .none: return "Not recording"
        }
    }

    private var stateDetail: String {
        switch phase {
        case .preparing: return "Waiting for the microphone."
        case .recording:
            return "Speak now. Press Stop to transcribe, or Cancel to discard. Limit \(AppSettings.clock(context.settings.effectiveRecordingLimitSeconds))."
        case .transcribing: return "Uploading the recording to your endpoint and waiting for the text."
        case .inserting: return "Inserting the transcript."
        case .resultReady: return "Edit, Copy, or Record again."
        case .failed: return coordinator.activeSession?.errorMessage ?? "Something went wrong."
        case .completed: return coordinator.activeSession?.insertionOutcome?.userMessage ?? "Transcript delivered."
        case .canceled: return "Recording discarded. Press Record to start again."
        case .idle, .none: return "Press Record here, or \(context.settings.shortcut.displayString) in any app."
        }
    }

    private var stateColor: Color {
        switch phase {
        case .recording: return .red
        case .preparing, .transcribing, .inserting: return .accentColor
        case .resultReady, .completed: return .green
        case .failed: return .orange
        case .idle, .canceled, .none: return .secondary
        }
    }

    private var stateStrip: some View {
        HStack(spacing: 12) {
            StateDot(color: stateColor, pulsing: isRecording && !reduceMotion)
            VStack(alignment: .leading, spacing: 2) {
                Text(stateTitle).font(.title3.weight(.semibold))
                Text(stateDetail)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if isRecording {
                Text(formatElapsed(coordinator.recordingDuration))
                    .font(.title2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.red)
                    .accessibilityLabel("Elapsed \(formatElapsed(coordinator.recordingDuration))")
            } else if phase == .preparing || phase == .transcribing || phase == .inserting {
                ProgressView().controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(stateColor.opacity(phase == nil || phase == .idle || phase == .canceled ? 0.08 : 0.13),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(stateColor.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stateTitle). \(stateDetail)")
    }

    // MARK: Notices and insertion outcome

    @ViewBuilder
    private var statusBanner: some View {
        if let notice = coordinator.noticeMessage {
            HStack {
                Text(notice).font(.callout)
                Spacer()
                Button("Dismiss") { coordinator.clearNotice() }
            }
            .padding(8)
            .background(Color.accentColor.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
        }
        if let session = coordinator.activeSession, session.phase == .resultReady,
           let outcome = session.insertionOutcome {
            Text(outcome.userMessage).font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Controls — the one action that applies right now is the prominent button

    private var recordControls: some View {
        HStack(spacing: 8) {
            Button {
                let result = coordinator.startInAppSession()
                if case .busy(let message) = result { coordinator.postNotice(message) }
                if case .invalidEndpoint(let message) = result { coordinator.postNotice(message) }
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLive)
            .accessibilityLabel("Start recording in this window")

            Button {
                coordinator.stopAndTranscribe()
            } label: {
                Label("Stop & transcribe", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!isRecording)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("Stop recording and transcribe")

            Button("Cancel") { coordinator.cancelActive() }
                .buttonStyle(.bordered)
                .disabled(!isLive)
                .accessibilityLabel("Cancel without transcribing")
            Spacer()
            Button("Copy") { copyActive() }
                .buttonStyle(.bordered)
                .disabled(activeTranscript == nil)
            Button("Clear") { clearActive() }
                .buttonStyle(.bordered)
                .disabled(activeTranscript == nil && coordinator.activeSession == nil)
        }
    }

    // MARK: Transcript

    private var transcriptPlaceholder: String {
        switch phase {
        case .preparing: return "Preparing the microphone…"
        case .recording: return "Recording… The transcript appears here after you press Stop."
        case .transcribing: return "Transcribing… waiting for your endpoint."
        case .failed: return "No transcript. See the error above; Retry if the audio was kept."
        default: return "Nothing transcribed yet. Press Record, speak, then press Stop."
        }
    }

    private var transcriptEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Transcript").font(.headline)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $editBuffer)
                    .font(.body)
                    .frame(minHeight: 140)
                    .border(Color.secondary.opacity(0.3))
                    .accessibilityLabel("Transcript editor")
                    .disabled(activeTranscript == nil)
                if editBuffer.isEmpty {
                    Text(transcriptPlaceholder)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            if hasEdits {
                HStack {
                    Text("Edited — applies to Copy and any later Insert.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Apply edit") { applyEdit() }
                        .accessibilityLabel("Apply transcript edit")
                }
            }
            if coordinator.activeSession?.phase == .failed,
               coordinator.activeSession?.retryable == true,
               let id = coordinator.activeSession?.id {
                Button("Retry with kept audio") { coordinator.retry(sessionID: id) }
                    .accessibilityLabel("Retry transcription")
            }
        }
    }

    private var hasEdits: Bool {
        guard let id = editingSessionID,
              id == coordinator.activeSession?.id,
              let original = activeTranscript
        else { return false }
        return editBuffer != original
    }

    private func syncEditor() {
        editingSessionID = coordinator.activeSession?.id
        editBuffer = coordinator.activeSession?.transcript ?? ""
    }

    private func applyEdit() {
        guard let id = coordinator.activeSession?.id else { return }
        coordinator.updateTranscript(sessionID: id, text: editBuffer)
    }

    private func copyActive() {
        guard let id = coordinator.activeSession?.id else { return }
        // Copy the buffer if the user edited but hasn't applied — Copy means
        // "what I see". Apply first so Copy and Insert agree.
        if hasEdits { coordinator.updateTranscript(sessionID: id, text: editBuffer) }
        if let text = coordinator.transcriptForCopy(sessionID: id) {
            context.copyToClipboard(text)
        }
    }

    private func clearActive() {
        if let id = coordinator.activeSession?.id {
            coordinator.discardSession(id: id)
        }
        editBuffer = ""
        editingSessionID = nil
    }

    @ViewBuilder
    private var retainedList: some View {
        if !coordinator.retainedSessions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Kept results (this session only — not saved to disk)").font(.headline)
                ForEach(coordinator.retainedSessions, id: \.id) { session in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading) {
                            Text(session.transcript ?? session.errorMessage ?? "(no text)")
                                .lineLimit(2).font(.callout)
                            Text(session.phase.rawValue).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if session.transcript != nil {
                            Button("Copy") {
                                if let text = coordinator.transcriptForCopy(sessionID: session.id) {
                                    context.copyToClipboard(text)
                                }
                            }
                            if session.isExternal {
                                Button("Insert") { coordinator.insertExplicitly(sessionID: session.id) }
                            }
                        }
                        if session.phase == .failed, session.retryable {
                            Button("Retry") { coordinator.retry(sessionID: session.id) }
                        }
                        Button("Discard") { coordinator.discardSession(id: session.id) }
                    }
                    .buttonStyle(.borderless)
                    Divider()
                }
            }
        }
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Solid state dot. Pulses only while recording, and only when the user has
/// not asked for reduced motion; the strip's title text carries the meaning.
private struct StateDot: View {
    var color: Color
    var pulsing: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 14, height: 14)
            .opacity(pulsing && dim ? 0.35 : 1)
            .animation(pulsing ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: dim)
            .onAppear { dim = pulsing }
            .onChange(of: pulsing) { _, now in dim = now }
            .accessibilityHidden(true)
    }
}

// MARK: - Settings tab

private struct SettingsTab: View {
    @ObservedObject private var context = AppContext.shared
    @State private var tokenDraft: String = ""
    @State private var tokenRevealed = false
    @State private var testResult: AppContext.ConnectionTestResult?
    @State private var isTesting = false

    // Grouped form: label column + expanding content column, scrolls when
    // tall. (The default column style sized its label column from the long
    // text-field titles and pushed every control off the right edge.)
    var body: some View {
        Form {
            endpointSection
            insertionSection
            shortcutSection
            audioNetworkSection
        }
        .formStyle(.grouped)
    }

    // MARK: Sections

    private var endpointSection: some View {
        Section {
            LabeledContent("Request URL") {
                TextField("https://host/v1/audio/transcriptions", text: $context.settings.endpointURLString)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Transcription endpoint URL")
            }
            if context.settings.usesInsecureHTTP {
                Text("Plain HTTP: fine for localhost/LAN development; prefer HTTPS for remote servers.")
                    .font(.caption).foregroundStyle(.orange)
            }
            LabeledContent("Model") {
                TextField("Optional — sent only when set", text: $context.settings.model)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Model, optional")
            }
            LabeledContent("Language") {
                TextField("Optional, e.g. en — sent only when set", text: $context.settings.language)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Language, optional")
            }
            LabeledContent("Bearer token") {
                HStack(spacing: 8) {
                    Group {
                        if tokenRevealed {
                            TextField(tokenPlaceholder, text: $tokenDraft)
                        } else {
                            SecureField(tokenPlaceholder, text: $tokenDraft)
                        }
                    }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Bearer token")
                    Button(tokenRevealed ? "Hide" : "Show") { tokenRevealed.toggle() }
                        .accessibilityLabel(tokenRevealed ? "Hide token" : "Show token")
                    Button("Save token") {
                        context.saveToken(tokenDraft.isEmpty ? nil : tokenDraft)
                        tokenDraft = ""
                    }
                    .disabled(tokenDraft.isEmpty)
                    if context.hasToken {
                        Button("Clear token") {
                            context.saveToken(nil)
                            tokenDraft = ""
                        }
                    }
                }
            }
            Text(context.hasToken
                 ? "A token is saved in Keychain (never shown or logged) and sent as “Authorization: Bearer …”."
                 : "No token saved. Tokens live in Keychain only and are sent as “Authorization: Bearer …”.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Connection check") {
                HStack(spacing: 8) {
                    Button("Send 0.5 s test tone") { runTest() }
                        .disabled(isTesting)
                        .accessibilityLabel("Test connection by uploading a generated half-second test tone")
                    if isTesting { ProgressView().controlSize(.small) }
                }
            }
            if let testResult {
                Text(testResult.message)
                    .font(.callout)
                    .foregroundStyle(testResult.succeeded ? .green : .red)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Transcription endpoint")
        } footer: {
            Text("Enter the full URL including the path — the app sends exactly what you configure. The connection check uploads a generated tone through the real adapter; there is no universal health endpoint, and a real speech recognizer returns an empty transcript for a tone.")
        }
    }

    private var tokenPlaceholder: String {
        context.hasToken ? "Token is set (hidden) — enter a new one to replace it" : "Paste API key or session token"
    }

    private var insertionSection: some View {
        Section {
            Picker("Mode", selection: $context.settings.insertionMode) {
                ForEach(InsertionMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        } header: {
            Text("Insertion")
        } footer: {
            Text("Automatic insertion happens at most once, and only when the original app, field, and caret still validate.")
        }
    }

    private var shortcutSection: some View {
        Section {
            LabeledContent("Global shortcut") {
                HStack(spacing: 8) {
                    Text(context.settings.shortcut.displayString)
                        .font(.body.monospaced())
                        .accessibilityLabel("Current shortcut \(context.settings.shortcut.displayString)")
                    ShortcutRecorder(shortcut: $context.settings.shortcut)
                    Button("Reset") { context.settings.shortcut = .default }
                }
            }
        } header: {
            Text("Shortcut")
        } footer: {
            Text("Press it in another app to start; press again to stop and transcribe. Key-repeat never double-toggles.")
        }
    }

    private var audioNetworkSection: some View {
        Section {
            LabeledContent("Input device", value: context.inputDeviceName())
            LabeledContent("Request timeout") {
                secondsField($context.settings.requestTimeout, label: "Request timeout in seconds")
            }
            LabeledContent("Resource timeout") {
                secondsField($context.settings.resourceTimeout, label: "Total resource timeout in seconds")
            }
            LabeledContent("Max upload") {
                intField($context.settings.maxUploadMB, unit: "MB", label: "Maximum upload size in megabytes")
            }
            LabeledContent("Max recording length") {
                intField($context.settings.maxRecordingMinutes, unit: "min", label: "Maximum recording length in minutes")
            }
            LabeledContent("Effective limit", value: AppSettings.clock(context.settings.effectiveRecordingLimitSeconds))
        } header: {
            Text("Audio & network")
        } footer: {
            Text("The request timeout is how long to wait for the server's reply after the upload — raise it for CPU transcription. Recording stops with a message at the effective limit: the length above, capped so the 16 kHz mono upload never exceeds Max upload (about 13:39 per 25 MB). Audio is never truncated silently.")
        }
    }

    // MARK: Field helpers

    private func secondsField(_ value: Binding<TimeInterval>, label: String) -> some View {
        HStack(spacing: 6) {
            TextField("", value: value, format: .number)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .accessibilityLabel(label)
            Text("s").foregroundStyle(.secondary)
        }
    }

    private func intField(_ value: Binding<Int>, unit: String, label: String) -> some View {
        HStack(spacing: 6) {
            TextField("", value: value, format: .number)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .accessibilityLabel(label)
            Text(unit).foregroundStyle(.secondary)
        }
    }

    private func runTest() {
        isTesting = true
        testResult = nil
        Task {
            let result = await context.testConnection()
            testResult = result
            isTesting = false
        }
    }
}

// MARK: - Shortcut recorder

private struct ShortcutRecorder: View {
    @Binding var shortcut: ShortcutConfig
    @State private var capturing = false
    @State private var monitor: Any?

    var body: some View {
        Button(capturing ? "Press keys… (Esc cancels)" : "Capture") {
            capturing ? stopCapture() : startCapture()
        }
        .accessibilityLabel("Capture a new global shortcut")
    }

    private func startCapture() {
        capturing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape: cancel
                stopCapture()
                return nil
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.isEmpty else { return event } // require at least one modifier
            var carbon: UInt32 = 0
            if flags.contains(.command) { carbon |= 256 }
            if flags.contains(.shift) { carbon |= 512 }
            if flags.contains(.option) { carbon |= 2048 }
            if flags.contains(.control) { carbon |= 4096 }
            shortcut = ShortcutConfig(keyCode: UInt32(event.keyCode), carbonModifiers: carbon)
            stopCapture()
            return nil
        }
    }

    private func stopCapture() {
        capturing = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

// MARK: - Permissions tab

private struct PermissionsTab: View {
    @ObservedObject private var context = AppContext.shared
    @State private var micStatus: MicStatus = MicrophonePermission.status()
    @State private var axTrusted: Bool = false

    var body: some View {
        Form {
            Section("Microphone — required for recording") {
                statusRow(label: micLabel, ok: micStatus == .authorized)
                if micStatus != .authorized {
                    Text("Recording is blocked until access is granted. After granting, return here and press Recheck.")
                        .font(.caption)
                    Button("Open Microphone settings") { context.openMicrophoneSettings() }
                }
            }
            Section("Accessibility — required for auto-insert into other apps") {
                statusRow(label: axTrusted ? "Granted" : "Not granted", ok: axTrusted)
                Text("Without it you can still record, transcribe, and Copy — automatic insertion is disabled and transcripts are kept for manual copy.")
                    .font(.caption)
                HStack {
                    Button("Request access") { context.destinations.promptForTrust() }
                    Button("Open Accessibility settings") { context.openAccessibilitySettings() }
                }
                Text("Note: rebuilding the app or changing its signing identity can invalidate the grant; re-enable Open Dictation in the list if insertion stops working after an update.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("What this app does NOT need") {
                Text("• Input Monitoring is not requested — the global shortcut uses a hotkey registration, not keystroke observation.\n• Speech-recognition authorization is not requested — transcription goes to your endpoint.\n• No account, subscription, telemetry, or internet beyond your endpoint.")
                    .font(.callout)
            }
            Button("Recheck permissions") { recheck() }
        }
        .formStyle(.grouped)
        .onAppear { recheck() }
    }

    private var micLabel: String {
        switch micStatus {
        case .authorized: return "Granted"
        case .denied: return "Denied"
        case .notDetermined: return "Not asked yet (press Record to be asked)"
        }
    }

    private func statusRow(label: String, ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(label)
        }
        .accessibilityElement(children: .combine)
    }

    private func recheck() {
        micStatus = MicrophonePermission.status()
        axTrusted = context.destinations.accessibilityTrusted
    }
}

// MARK: - Menu bar

struct MenuBarView: View {
    @ObservedObject private var context = AppContext.shared
    @ObservedObject private var coordinator = AppContext.shared.coordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusText).font(.callout)
        Divider()
        Button(toggleLabel, action: toggle)
            .disabled(toggleDisabled)
        Button("Open Open Dictation window") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        Divider()
        Button("Quit Open Dictation") { NSApp.terminate(nil) }
    }

    private var statusText: String {
        guard let session = coordinator.activeSession else { return "Idle" }
        switch session.phase {
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .inserting: return "Inserting…"
        case .resultReady: return "Transcript ready"
        case .failed: return "Failed"
        case .completed: return session.insertionOutcome?.userMessage ?? "Done"
        case .canceled: return "Canceled"
        case .preparing: return "Preparing…"
        case .idle: return "Idle"
        }
    }

    private var toggleLabel: String {
        coordinator.activeSession?.phase == .recording ? "Stop and transcribe" : "Start dictation here"
    }

    private var toggleDisabled: Bool {
        guard let phase = coordinator.activeSession?.phase else { return false }
        switch phase {
        case .preparing, .transcribing, .inserting: return true
        default: return false
        }
    }

    private func toggle() {
        if coordinator.activeSession?.phase == .recording {
            coordinator.stopAndTranscribe()
        } else {
            let result = coordinator.startExternalSession()
            if case .busy(let message) = result { coordinator.postNotice(message) }
            if case .invalidEndpoint(let message) = result { coordinator.postNotice(message) }
        }
    }
}
