import Foundation

// MARK: - Deterministic fake provider for UI exercise and tests.

public actor FakeProvider: TranscriptionProvider {
    public struct RecordedRequest: Sendable {
        public var audioBytes: Int
        public var endpointURL: URL
        public var model: String?
        public var language: String?
        public var hadAuthHeader: Bool
    }

    public enum Script: Sendable {
        case succeed(text: String)
        case fail(ProviderError)
        case succeedAfterFailures(text: String, failures: Int, error: ProviderError)
    }

    private var recorded: [RecordedRequest] = []
    private let script: Script
    private let delayNanoseconds: UInt64
    private var remainingFailures: Int

    public init(script: Script = .succeed(text: "FAKE TRANSCRIPT: hello world."), delayNanoseconds: UInt64 = 0) {
        self.script = script
        self.delayNanoseconds = delayNanoseconds
        switch script {
        case .succeedAfterFailures(_, let failures, _): self.remainingFailures = failures
        default: self.remainingFailures = 0
        }
    }

    public var requests: [RecordedRequest] { recorded }

    public func transcribe(audioURL: URL, config: ProviderConfig) async throws -> TranscriptResult {
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        try Task.checkCancellation()

        let size = (try? Data(contentsOf: audioURL).count) ?? 0
        recorded.append(RecordedRequest(
            audioBytes: size,
            endpointURL: config.endpointURL,
            model: config.model,
            language: config.language,
            hadAuthHeader: config.bearerToken != nil
        ))

        switch script {
        case .succeed(let text):
            return TranscriptResult(text: text)
        case .fail(let error):
            throw error
        case .succeedAfterFailures(let text, _, let error):
            if remainingFailures > 0 {
                remainingFailures -= 1
                throw error
            }
            return TranscriptResult(text: text)
        }
    }
}
