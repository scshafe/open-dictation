import AppKit
import Combine
import OpenDictationCore
import SwiftUI

// MARK: - App entry: regular app + menu bar, one shared main window

@main
struct OpenDictationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var context = AppContext.shared
    @ObservedObject private var coordinator = AppContext.shared.coordinator

    var body: some Scene {
        Window("Open Dictation", id: "main") {
            MainView()
        }
        .windowResizability(.contentSize)

        MenuBarExtra("Open Dictation", systemImage: menuBarIcon) {
            MenuBarView()
        }

        Settings {
            // Settings live in the main window's Settings tab; keep the
            // standard Cmd-, entry point pointing at a hint.
            VStack(spacing: 12) {
                Text("Settings live in the main window's Settings tab.")
                    .font(.callout)
                    .padding()
            }
            .frame(width: 360, height: 120)
        }
    }

    private var menuBarIcon: String {
        switch coordinator.activeSession?.phase {
        case .recording: return "mic.fill"
        case .transcribing, .inserting: return "ellipsis.circle"
        default: return "mic"
        }
    }
}

// MARK: - Delegate: shortcut, panel, lifecycle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let shortcuts = ShortcutManager()
    private var panelController: FloatingPanelController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let context = AppContext.shared
        // Clean up abandoned temp recordings from previous runs.
        let removed = TempAudioStore.shared.cleanupAbandoned()
        if removed > 0 {
            NSLog("OpenDictation: removed %d abandoned temp file(s)", removed)
        }

        // Global shortcut: start/stop toggle.
        shortcuts.onHotKey = { [weak self] in self?.toggleDictation() }
        registerShortcutFromSettings()
        context.$settings
            .map(\.shortcut)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.registerShortcutFromSettings() }
            .store(in: &cancellables)

        // Floating panel follows external-session state.
        panelController = FloatingPanelController(coordinator: context.coordinator)

        // Sleep: stop the mic, never insert. Wake: nothing automatic.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
    }

    /// Closing the window must NOT terminate background shortcut functionality.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppContext.shared.coordinator.handleTermination()
    }

    @objc private func systemWillSleep() {
        AppContext.shared.coordinator.handleSystemSleep()
    }

    // MARK: Shortcut

    private func registerShortcutFromSettings() {
        let context = AppContext.shared
        let shortcut = context.settings.shortcut
        do {
            try shortcuts.register(keyCode: shortcut.keyCode, carbonModifiers: shortcut.carbonModifiers)
        } catch let error as ShortcutManager.ShortcutError {
            context.coordinator.postNotice(error.localizedDescription)
        } catch {
            context.coordinator.postNotice("Could not register the shortcut.")
        }
    }

    /// Shortcut semantics: recording → stop & transcribe; transcribing →
    /// ignore (must not double-toggle); otherwise → start external session.
    private func toggleDictation() {
        let coordinator = AppContext.shared.coordinator
        switch coordinator.activeSession?.phase {
        case .recording:
            coordinator.stopAndTranscribe()
        case .preparing, .transcribing, .inserting:
            break // ignore repeats / mid-flight presses
        default:
            let result = coordinator.startExternalSession()
            switch result {
            case .started:
                if !AppContext.shared.destinations.accessibilityTrusted {
                    coordinator.postNotice("Accessibility is not granted: the transcript will be kept for Copy. See Permissions.")
                }
            case .busy(let message), .invalidEndpoint(let message):
                coordinator.postNotice(message)
            }
        }
    }
}
