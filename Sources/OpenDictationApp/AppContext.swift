import AppKit
import AVFoundation
import Combine
import Foundation
import OpenDictationCore
import os

// MARK: - Composition root
//
// `shared` wires the live dependencies for the running app. It is the entry
// point's wiring, not load-bearing mutable global state: tests construct
// their own SessionCoordinator with fakes and never touch this.

@MainActor
private final class LiveConfigSource: SessionConfigSource {
    weak var context: AppContext?
    func currentSettings() -> AppSettings { context?.settings ?? AppSettings() }
    func currentToken() -> String? { context?.loadToken() }
}

@MainActor
final class AppContext: ObservableObject {
    static let shared = AppContext()

    /// NOTE: this context does NOT forward the coordinator's change
    /// notifications. Views that render session state must declare
    /// `@ObservedObject var coordinator = AppContext.shared.coordinator`
    /// themselves; observing only `context` leaves them frozen mid-session.
    let coordinator: SessionCoordinator
    let settingsStore = SettingsStore()
    let tokenStore = KeychainTokenStore()
    let destinations = AXDestinationService()
    let inserter = AXInsertionService()

    @Published var settings: AppSettings
    @Published var hasToken: Bool = false

    private var cancellables = Set<AnyCancellable>()

    private init() {
        let initialSettings = settingsStore.load()
        self.settings = initialSettings
        let source = LiveConfigSource()
        self.coordinator = SessionCoordinator(
            makeRecorder: { AudioRecorder() },
            converter: AudioFileConverter(),
            makeProvider: { HTTPTranscriptionAdapter() },
            inserter: inserter,
            destinations: destinations,
            configSource: source
        )
        source.context = self
        // Reasons only (never transcript text/audio/tokens); see
        // SessionCoordinator.diagnostics. Marked public on purpose so
        // `log show` prints them instead of <private>.
        let log = Logger(subsystem: "com.example.opendictation", category: "session")
        coordinator.diagnostics = { line in log.notice("\(line, privacy: .public)") }
        self.hasToken = loadToken() != nil

        $settings
            .dropFirst()
            .sink { [weak self] value in self?.settingsStore.save(value) }
            .store(in: &cancellables)
    }

    // MARK: - Token (Keychain only)

    func loadToken() -> String? { tokenStore.loadToken() }

    func saveToken(_ token: String?) {
        try? tokenStore.saveToken(token)
        hasToken = !(token ?? "").isEmpty
    }

    // MARK: - Connection check (documented meaning)
    //
    // There is no universal "health endpoint" for transcription servers, so
    // this check uploads a generated 0.5s test tone through the real adapter
    // and reports what the server returns. The UI labels it exactly as that.

    struct ConnectionTestResult {
        var succeeded: Bool
        var message: String
    }

    func testConnection() async -> ConnectionTestResult {
        guard let config = settings.providerConfig(bearerToken: loadToken()) else {
            return ConnectionTestResult(succeeded: false, message: "Endpoint URL is invalid.")
        }
        let url = TempAudioStore.shared.newURL(suffix: "wav")
        do {
            let samples = WAVFile.sineSamples(sampleRate: WAVFile.targetSampleRate, seconds: 0.5, frequency: 440)
            try WAVFile.writePCM16Mono(to: url, samples: samples, sampleRate: WAVFile.targetSampleRate)
            let result = try await HTTPTranscriptionAdapter().transcribe(audioURL: url, config: config)
            TempAudioStore.shared.delete(url)
            return ConnectionTestResult(succeeded: true, message: "Server responded: “\(result.text.prefix(160))”")
        } catch ProviderError.emptyTranscript {
            // A real speech recognizer has nothing to say about a pure tone:
            // the upload was accepted and processed, so transport and
            // authentication work. Only a mock returns text for a tone.
            TempAudioStore.shared.delete(url)
            return ConnectionTestResult(
                succeeded: true,
                message: "Server accepted the upload and returned an empty transcript for the test tone (expected from a real speech recognizer). Transport and authentication work."
            )
        } catch let error as ProviderError {
            TempAudioStore.shared.delete(url)
            return ConnectionTestResult(succeeded: false, message: error.userMessage)
        } catch {
            TempAudioStore.shared.delete(url)
            return ConnectionTestResult(succeeded: false, message: "Connection check failed.")
        }
    }

    // MARK: - Device + clipboard + settings links

    /// First release uses the system default input; shown here for transparency.
    func inputDeviceName() -> String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "System default input"
    }

    /// Deliberate user copy: no clipboard restoration afterwards.
    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func openMicrophoneSettings() {
        openPrivacyPane("Privacy_Microphone")
    }

    func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    private func openPrivacyPane(_ pane: String) {
        let deepLink = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)")!
        if !NSWorkspace.shared.open(deepLink) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
        }
    }
}
