import AppKit
import Combine
import OpenDictationCore
import SwiftUI

// MARK: - Nonactivating floating panel
//
// Style alone is not proof of focus behavior: the controller records a
// focus check (frontmost app before/after show, and whether our app became
// active) on every presentation. See docs/VERIFICATION.md for the manual
// procedure; the recorded check is exposed for it.

final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .closable, .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        // Visible across Spaces; docks as an accessory in full-screen.
        // Full-screen Spaces need device testing (see VERIFICATION.md).
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        animationBehavior = .none
    }

    /// Clicks on Stop/Cancel must work WITHOUT activating the app or stealing
    /// keyboard focus from the destination.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Recorded evidence for the no-focus-theft verification procedure.
struct PanelFocusCheck {
    var shownAt: Date
    var frontmostBefore: String?
    var frontmostAfter: Date?
    var frontmostAfterBundle: String?
    var appBecameActive: Bool
}

@MainActor
final class FloatingPanelController {
    private let coordinator: SessionCoordinator
    private var panel: FloatingPanel?
    private var cancellables = Set<AnyCancellable>()
    private(set) var lastFocusCheck: PanelFocusCheck?

    init(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
        coordinator.$activeSession
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncVisibility() }
            .store(in: &cancellables)
    }

    private func syncVisibility() {
        guard let session = coordinator.activeSession, session.isExternal else {
            hide()
            return
        }
        switch session.phase {
        case .preparing, .recording, .transcribing, .inserting, .resultReady, .failed:
            show(session: session)
        case .idle, .completed, .canceled:
            hide()
        }
    }

    private func show(session: DictationSession) {
        let before = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let wasActive = NSApp.isActive
        if panel == nil {
            let width: CGFloat = 340
            let height: CGFloat = 210
            let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height))
            let view = FloatingPanelView(coordinator: coordinator)
            panel.contentView = NSHostingView(rootView: view)
            position(panel)
            self.panel = panel
        }
        if let panel, !panel.isVisible {
            panel.orderFrontRegardless()
        }
        // Record (not assert) focus behavior for verification.
        lastFocusCheck = PanelFocusCheck(
            shownAt: Date(),
            frontmostBefore: before,
            frontmostAfter: Date(),
            frontmostAfterBundle: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            appBecameActive: NSApp.isActive && !wasActive
        )
        if lastFocusCheck?.appBecameActive == true || lastFocusCheck?.frontmostAfterBundle != before {
            NSLog("OpenDictation: panel show changed focus (before=%@ after=%@)",
                  before ?? "nil", lastFocusCheck?.frontmostAfterBundle ?? "nil")
        }
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Place on the display with the mouse (the active work) and clamp to the
    /// visible area. Top-center keeps it out of the way of most carets.
    private func position(_ panel: FloatingPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        var origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - 48
        )
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
    }
}

// MARK: - Panel content (SwiftUI hosted in the NSPanel)

struct FloatingPanelView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusRow
            if let session = coordinator.activeSession {
                switch session.phase {
                case .recording:
                    LevelMeterView(level: coordinator.micLevel)
                        .accessibilityLabel("Microphone level")
                    elapsedRow
                    controlsRow(stopEnabled: true)
                case .preparing:
                    Text("Preparing…").font(.callout).foregroundStyle(.secondary)
                    controlsRow(stopEnabled: false)
                case .transcribing, .inserting:
                    ProgressView()
                        .progressViewStyle(.circular)
                        .accessibilityLabel(session.phase == .transcribing ? "Transcribing" : "Inserting")
                    Text(session.phase == .transcribing ? "Transcribing…" : "Inserting…")
                        .font(.callout).foregroundStyle(.secondary)
                    controlsRow(stopEnabled: false)
                case .resultReady:
                    resultText(session)
                    resultControls(session)
                case .failed:
                    Text(session.errorMessage ?? "Something went wrong.")
                        .font(.callout).foregroundStyle(.red)
                        .accessibilityLabel("Error: \(session.errorMessage ?? "unknown")")
                    failedControls(session)
                case .completed, .canceled, .idle:
                    Text(session.insertionOutcome?.userMessage ?? "Done.")
                        .font(.callout).foregroundStyle(.secondary)
                    controlsRow(stopEnabled: false)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            recordingDot
            Text(titleText)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var recordingDot: some View {
        let recording = coordinator.activeSession?.phase == .recording
        Circle()
            .fill(recording ? Color.red : Color.secondary)
            .frame(width: 10, height: 10)
            // Shape + text label (never color-only): the title text names the state.
            .accessibilityHidden(true)
    }

    private var titleText: String {
        switch coordinator.activeSession?.phase {
        case .recording: return "Recording"
        case .preparing: return "Preparing"
        case .transcribing: return "Transcribing"
        case .inserting: return "Inserting"
        case .resultReady: return "Transcript ready"
        case .failed: return "Dictation failed"
        case .completed: return "Done"
        case .canceled: return "Canceled"
        case .idle, .none: return "Open Dictation"
        }
    }

    private var elapsedRow: some View {
        Text("Elapsed \(formatElapsed(coordinator.recordingDuration))")
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityLabel("Elapsed recording time \(formatElapsed(coordinator.recordingDuration))")
    }

    private func controlsRow(stopEnabled: Bool) -> some View {
        HStack {
            Button("Stop") { coordinator.stopAndTranscribe() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!stopEnabled)
                .accessibilityLabel("Stop recording and transcribe")
            Button("Cancel") { coordinator.cancelActive() }
                .accessibilityLabel("Cancel recording without transcribing")
            Spacer()
            Button("Editor") {
                coordinator.noteEditorOpened()
                NSApp.activate(ignoringOtherApps: true)
            }
            .accessibilityLabel("Open transcript in editor (keeps result, disables auto-insert)")
        }
        .buttonStyle(.bordered)
    }

    private func resultText(_ session: DictationSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.transcript ?? "")
                .font(.body)
                .lineLimit(4)
                .textSelection(.enabled)
            if let outcome = session.insertionOutcome {
                Text(outcome.userMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func resultControls(_ session: DictationSession) -> some View {
        HStack {
            Button("Copy") {
                if let text = coordinator.transcriptForCopy(sessionID: session.id) {
                    AppContext.shared.copyToClipboard(text)
                }
            }
            .accessibilityLabel("Copy transcript to clipboard")
            Button("Insert") { coordinator.insertExplicitly(sessionID: session.id) }
                .accessibilityLabel("Insert transcript into the original field")
            Button("Discard") { coordinator.discardSession(id: session.id) }
                .accessibilityLabel("Discard this transcript")
        }
        .buttonStyle(.bordered)
    }

    private func failedControls(_ session: DictationSession) -> some View {
        HStack {
            if session.retryable {
                Button("Retry") { coordinator.retry(sessionID: session.id) }
                    .accessibilityLabel("Retry transcription with the kept audio")
            }
            Button("Copy error") {
                AppContext.shared.copyToClipboard(session.errorMessage ?? "Unknown error")
            }
            Button("Dismiss") { coordinator.discardSession(id: session.id) }
        }
        .buttonStyle(.bordered)
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Simple level meter. No animation dependency: width follows the measured
/// level directly, so reduced-motion users get identical information.
struct LevelMeterView: View {
    var level: Float // 0...1 measured RMS

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.25))
                RoundedRectangle(cornerRadius: 4)
                    .fill(levelColor)
                    .frame(width: geometry.size.width * CGFloat(min(1, max(0, level))))
            }
        }
        .frame(height: 10)
        .accessibilityValue("\(Int(level * 100)) percent")
    }

    private var levelColor: Color {
        level > 0.9 ? .red : (level > 0.6 ? .orange : .green)
    }
}
