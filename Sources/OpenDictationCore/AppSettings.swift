import Foundation

// MARK: - Shortcut configuration

/// Global hotkey stored as Carbon key code + modifier flags so Settings can
/// persist it and the Carbon-based ShortcutManager can register it directly.
public struct ShortcutConfig: Codable, Equatable, Sendable {
    /// Carbon virtual key code (e.g. 49 = Space).
    public var keyCode: UInt32
    /// Carbon modifier flags (cmdKey=256 shiftKey=512 optionKey=2048 controlKey=4096).
    public var carbonModifiers: UInt32

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// Proposed default: Option-Shift-Space. Subject to conflict checking at
    /// registration; the user can reassign in Settings.
    public static var `default`: ShortcutConfig {
        ShortcutConfig(keyCode: 49, carbonModifiers: 2048 | 512)
    }

    public var displayString: String {
        var parts: [String] = []
        if carbonModifiers & 4096 != 0 { parts.append("⌃") }
        if carbonModifiers & 256 != 0 { parts.append("⌘") }
        if carbonModifiers & 2048 != 0 { parts.append("⌥") }
        if carbonModifiers & 512 != 0 { parts.append("⇧") }
        parts.append(Self.keyName(for: keyCode))
        return parts.joined()
    }

    public static func keyName(for keyCode: UInt32) -> String {
        switch keyCode {
        case 49: return "Space"
        case 36: return "↩"
        case 51: return "⌫"
        case 53: return "Esc"
        case 48: return "Tab"
        default: return "Key \(keyCode)"
        }
    }
}

// MARK: - App settings (ordinary preferences; secrets stay in Keychain)

public struct AppSettings: Codable, Equatable {
    public var endpointURLString: String
    public var model: String
    public var language: String
    public var insertionMode: InsertionMode
    public var shortcut: ShortcutConfig
    public var requestTimeout: TimeInterval
    public var resourceTimeout: TimeInterval
    public var maxUploadMB: Int
    /// Visible recording limits (no silent truncation; hitting them ends the
    /// recording with a message instead of cutting audio silently).
    public var maxRecordingMinutes: Int

    public init(
        endpointURLString: String = "http://127.0.0.1:8080/v1/audio/transcriptions",
        model: String = "",
        language: String = "",
        insertionMode: InsertionMode = .automaticWhenSafe,
        shortcut: ShortcutConfig = .default,
        requestTimeout: TimeInterval = 30,
        resourceTimeout: TimeInterval = 120,
        maxUploadMB: Int = 25,
        maxRecordingMinutes: Int = 15
    ) {
        self.endpointURLString = endpointURLString
        self.model = model
        self.language = language
        self.insertionMode = insertionMode
        self.shortcut = shortcut
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.maxUploadMB = maxUploadMB
        self.maxRecordingMinutes = maxRecordingMinutes
    }

    /// Bytes per second of the documented upload format (16 kHz mono 16-bit PCM).
    public static let uploadBytesPerSecond = 32_000

    /// The recording limit actually enforced: the configured minutes, capped so
    /// the converted WAV can never exceed the upload limit — otherwise a
    /// recording could run to the minute limit and then be refused at upload
    /// time (and lost). Shown in the UI as the effective limit.
    public var effectiveRecordingLimitSeconds: TimeInterval {
        let byMinutes = TimeInterval(max(1, maxRecordingMinutes) * 60)
        let byUpload = TimeInterval((max(1, maxUploadMB) * 1024 * 1024) / Self.uploadBytesPerSecond)
        return min(byMinutes, byUpload)
    }

    /// m:ss for limits and elapsed times.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    public var endpointURL: URL? {
        guard let url = URL(string: endpointURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }

    public var usesInsecureHTTP: Bool {
        endpointURL?.scheme?.lowercased() == "http"
    }

    /// Snapshot the current settings + Keychain token into an immutable config
    /// for one session (or one explicit retry). Returns nil when the URL is invalid.
    public func providerConfig(bearerToken: String?) -> ProviderConfig? {
        guard let url = endpointURL else { return nil }
        return ProviderConfig(
            endpointURL: url,
            model: model.isEmpty ? nil : model,
            language: language.isEmpty ? nil : language,
            bearerToken: (bearerToken?.isEmpty ?? true) ? nil : bearerToken,
            requestTimeout: requestTimeout,
            resourceTimeout: resourceTimeout,
            maxUploadBytes: max(1, maxUploadMB) * 1024 * 1024
        )
    }
}

public final class SettingsStore {
    private let defaults: UserDefaults
    private let key = "OpenDictation.AppSettings.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: key) else { return AppSettings() }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            return AppSettings()
        }
    }

    public func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}
