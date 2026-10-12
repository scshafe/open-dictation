import Foundation

// MARK: - Temporary audio lifecycle
//
// Private temp directory. Files live only while needed:
// - capture file: until conversion finishes (or discard)
// - converted WAV: until successful transcription, cancellation, or dismissal
//   of a retryable session; retained ONLY for explicit Retry.
// - abandoned files from a previous run: deleted on next launch.

public final class TempAudioStore {
    public static let shared = TempAudioStore()

    public let directory: URL
    private let fileManager = FileManager.default

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            self.directory = fileManager.temporaryDirectory
                .appendingPathComponent("OpenDictation", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public func newURL(suffix: String) -> URL {
        directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(suffix)
    }

    public func delete(_ url: URL?) {
        guard let url else { return }
        // Only delete files inside our own directory (safety against bad URLs).
        guard url.path.hasPrefix(directory.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    /// Delete abandoned recordings from previous runs. Call once at launch.
    /// - Returns: number of files removed.
    @discardableResult
    public func cleanupAbandoned() -> Int {
        guard let items = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return 0 }
        var removed = 0
        for item in items {
            do {
                try fileManager.removeItem(at: item)
                removed += 1
            } catch {
                continue
            }
        }
        return removed
    }
}
