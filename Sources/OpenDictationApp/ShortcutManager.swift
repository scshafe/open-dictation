import Carbon.HIToolbox
import Foundation

// MARK: - Global shortcut via Carbon hotkeys (public API)
//
// Why Carbon RegisterEventHotKey and not a CGEvent tap / global NSEvent monitor?
// Those observe the whole key stream and require Input Monitoring permission.
// A hotkey registration only fires for the one combination, needs no extra
// permission beyond the app itself, and delivers no key-repeat events (the OS
// sends exactly one press event), so key-repeat is inherently ignored.
//
// Tradeoff: the dedicated microphone (Fn/Globe) key and system-reserved
// combinations cannot be registered; a conventional modifier shortcut is used.

final class ShortcutManager {
    enum ShortcutError: LocalizedError, Equatable {
        case conflict
        case registrationFailed(OSStatus)
        case handlerFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .conflict:
                return "That shortcut is already in use. Pick a different combination in Settings."
            case .registrationFailed(let status):
                return "Could not register the shortcut (OSStatus \(status))."
            case .handlerFailed(let status):
                return "Could not install the hotkey handler (OSStatus \(status))."
            }
        }
    }

    /// Called on the main queue when the hotkey fires.
    var onHotKey: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private(set) var registered: ShortcutConfigLive?

    struct ShortcutConfigLive: Equatable {
        var keyCode: UInt32
        var carbonModifiers: UInt32
    }

    deinit {
        unregister()
    }

    /// Register `shortcut`, replacing any previous binding. Throws on conflict.
    func register(keyCode: UInt32, carbonModifiers: UInt32) throws {
        unregister()
        try installHandlerIfNeeded()

        var hotKeyID = EventHotKeyID(signature: OSType(0x4F704463), id: 1) // 'OpDc'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == eventHotKeyExistsErr {
            throw ShortcutError.conflict
        }
        guard status == noErr, let ref else {
            throw ShortcutError.registrationFailed(status)
        }
        hotKeyRef = ref
        registered = ShortcutConfigLive(keyCode: keyCode, carbonModifiers: carbonModifiers)
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        registered = nil
        // The handler stays installed for the app lifetime (cheap, one event type).
    }

    private func installHandlerIfNeeded() throws {
        if handlerRef != nil { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        var ref: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard err == noErr, hotKeyID.signature == OSType(0x4F704463), hotKeyID.id == 1 else {
                    return OSStatus(eventNotHandledErr)
                }
                let manager = Unmanaged<ShortcutManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { manager.onHotKey?() }
                return noErr
            } as EventHandlerUPP,
            1,
            &eventType,
            userData,
            &ref
        )
        guard status == noErr, let ref else {
            throw ShortcutError.handlerFailed(status)
        }
        handlerRef = ref
    }
}
