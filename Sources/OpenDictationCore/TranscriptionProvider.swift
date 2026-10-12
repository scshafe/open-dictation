import Foundation

// MARK: - Provider configuration (snapshotted per session)

public struct ProviderConfig: Equatable, Sendable {
    /// Full user-configured request URL, including path. Never guessed/appended.
    public var endpointURL: URL
    /// Model string, sent only when non-empty.
    public var model: String?
    /// Language hint, sent only when non-empty.
    public var language: String?
    /// Bearer token. Omit the Authorization header when nil/empty.
    /// Lives in Keychain at rest; never logged.
    public var bearerToken: String?
    public var requestTimeout: TimeInterval
    public var resourceTimeout: TimeInterval
    /// Refuse to upload files larger than this (visible limit, no silent truncation).
    public var maxUploadBytes: Int

    public init(
        endpointURL: URL,
        model: String? = nil,
        language: String? = nil,
        bearerToken: String? = nil,
        requestTimeout: TimeInterval = 30,
        resourceTimeout: TimeInterval = 120,
        maxUploadBytes: Int = 25 * 1024 * 1024
    ) {
        self.endpointURL = endpointURL
        self.model = (model?.isEmpty ?? true) ? nil : model
        self.language = (language?.isEmpty ?? true) ? nil : language
        self.bearerToken = (bearerToken?.isEmpty ?? true) ? nil : bearerToken
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.maxUploadBytes = maxUploadBytes
    }

    /// Debug description that never includes the token.
    public var redactedDescription: String {
        "endpoint=\(endpointURL.absoluteString) model=\(model ?? "(none)") " +
        "language=\(language ?? "(none)") auth=\(bearerToken == nil ? "none" : "bearer:set")"
    }
}

// MARK: - Result and errors

public struct TranscriptResult: Equatable, Sendable {
    /// Final transcript text, preserved verbatim from the provider.
    public var text: String
    public init(text: String) { self.text = text }
}

public enum ProviderError: Error, Equatable, Sendable {
    case transport(String)        // DNS, connectivity, TLS configuration, etc.
    case timeout
    case auth(String)             // 401/403
    case rateLimited
    case unsupportedUpload(String)// 413 / 415 / 422
    case server(String)           // 5xx
    case httpStatus(Int, String)  // other unexpected statuses
    case malformedResponse(String)
    case emptyTranscript
    case redirectBlocked(String)  // cross-origin redirect refused (no credential/audio forwarding)
    case uploadTooLarge(Int)      // local size guard, bytes attempted
    case cancelled

    /// Short user-facing message. Never contains secrets or transcript bodies.
    public var userMessage: String {
        switch self {
        case .transport(let d): return "Connection failed: \(d)"
        case .timeout: return "Request timed out. Check the endpoint and try again."
        case .auth: return "Authentication failed (401/403). Check the API token."
        case .rateLimited: return "Rate limited (429). Wait and retry."
        case .unsupportedUpload(let d): return "Server rejected the upload: \(d)"
        case .server(let d): return "Server error: \(d)"
        case .httpStatus(let code, _): return "Unexpected server response (HTTP \(code))."
        case .malformedResponse: return "Server returned an unrecognized response."
        case .emptyTranscript: return "Server returned an empty transcript."
        case .redirectBlocked: return "Redirect to a different origin was blocked to protect credentials and audio."
        case .uploadTooLarge(let n): return "Recording is \(n / 1024 / 1024) MB, over the upload limit. Shorten the recording."
        case .cancelled: return "Transcription was canceled."
        }
    }

    /// Failures worth keeping audio around for an explicit retry.
    public var keepsAudioForRetry: Bool {
        switch self {
        case .transport, .timeout, .rateLimited, .server, .httpStatus:
            return true
        case .auth, .unsupportedUpload, .malformedResponse, .emptyTranscript,
             .redirectBlocked, .uploadTooLarge, .cancelled:
            return false
        }
    }
}

// MARK: - Provider boundary

/// Minimal batch transcription abstraction. Recording/UI code depends only on this.
/// A future streaming provider adds a second protocol with partial/final events;
/// batch callers stay unchanged.
public protocol TranscriptionProvider: Sendable {
    func transcribe(audioURL: URL, config: ProviderConfig) async throws -> TranscriptResult
}

public struct TranscriptResponse: Decodable {
    public var text: String?
    public init(text: String?) { self.text = text }
}

public enum TranscriptResponseParser {
    /// Decode `{"text": "..."}` with explicit malformed vs. empty distinction.
    public static func parse(data: Data) throws -> TranscriptResult {
        let decoded: TranscriptResponse
        do {
            decoded = try JSONDecoder().decode(TranscriptResponse.self, from: data)
        } catch {
            throw ProviderError.malformedResponse("invalid JSON")
        }
        guard let text = decoded.text else {
            throw ProviderError.malformedResponse("missing 'text' field")
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProviderError.emptyTranscript
        }
        return TranscriptResult(text: text)
    }
}

public enum HTTPStatusClassifier {
    public static func error(statusCode: Int, bodyPrefix: String?) -> ProviderError {
        let detail = bodyPrefix ?? ""
        switch statusCode {
        case 200..<300: return .httpStatus(statusCode, "unexpected success path")
        // Same-origin redirects are followed by RedirectGuardDelegate; a 3xx
        // that reaches the adapter is a refused cross-origin redirect.
        case 300..<400: return .redirectBlocked("HTTP \(statusCode) redirect to another origin was refused")
        case 401, 403: return .auth(detail)
        case 413, 415, 422: return .unsupportedUpload(detail.isEmpty ? "HTTP \(statusCode)" : detail)
        case 429: return .rateLimited
        case 500..<600: return .server(detail.isEmpty ? "HTTP \(statusCode)" : detail)
        default: return .httpStatus(statusCode, detail)
        }
    }
}
