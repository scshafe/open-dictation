import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Real batch HTTP adapter implementing the multipart contract.

/// Redirect policy: same-origin redirects are followed; cross-origin redirects
/// are refused so bearer tokens and audio are never silently forwarded elsewhere.
public final class RedirectGuardDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    override public init() { super.init() }
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if Self.isSameOrigin(task.originalRequest?.url, request.url) {
            completionHandler(request)
        } else {
            // Refuse. URLSession then delivers the 3xx response itself, which
            // the adapter classifies as .redirectBlocked (HTTPStatusClassifier).
            completionHandler(nil)
        }
    }

    /// Origin = scheme + host + effective port (explicit, or the scheme default).
    public static func isSameOrigin(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b,
              let schemeA = a.scheme?.lowercased(), let schemeB = b.scheme?.lowercased(),
              let hostA = a.host?.lowercased(), let hostB = b.host?.lowercased()
        else { return false }
        return schemeA == schemeB && hostA == hostB && effectivePort(a) == effectivePort(b)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}

public final class HTTPTranscriptionAdapter: TranscriptionProvider, @unchecked Sendable {
    /// Bound response buffering: transcription JSON must fit in this.
    public static let maxResponseBytes = 1 * 1024 * 1024

    private let makeSession: @Sendable (ProviderConfig) -> URLSession

    public init(makeSession: (@Sendable (ProviderConfig) -> URLSession)? = nil) {
        if let makeSession {
            self.makeSession = makeSession
        } else {
            self.makeSession = { config in
                let sessionConfig = URLSessionConfiguration.ephemeral
                sessionConfig.timeoutIntervalForRequest = config.requestTimeout
                sessionConfig.timeoutIntervalForResource = config.resourceTimeout
                // Ephemeral: nothing cached to disk. Ordinary system TLS validation stays on.
                return URLSession(
                    configuration: sessionConfig,
                    delegate: RedirectGuardDelegate(),
                    delegateQueue: nil
                )
            }
        }
    }

    public func transcribe(audioURL: URL, config: ProviderConfig) async throws -> TranscriptResult {
        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioURL)
        } catch {
            throw ProviderError.transport("could not read recording file")
        }
        if audioData.count > config.maxUploadBytes {
            throw ProviderError.uploadTooLarge(audioData.count)
        }

        let (body, contentType) = MultipartRequestBuilder.buildBody(audioData: audioData, config: config)
        var request = URLRequest(url: config.endpointURL)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("OpenDictation/1.0", forHTTPHeaderField: "User-Agent")
        if let token = config.bearerToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let session = makeSession(config)
        defer { session.finishTasksAndInvalidate() }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.upload(for: request, from: body)
        } catch let urlError as URLError {
            throw Self.classify(urlError: urlError)
        } catch is CancellationError {
            throw ProviderError.cancelled
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.transport("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // Keep a short prefix for classification/debug; never inserted as text.
            let prefix = String(data: data.prefix(300), encoding: .utf8)
            throw HTTPStatusClassifier.error(statusCode: http.statusCode, bodyPrefix: prefix)
        }
        if data.count > Self.maxResponseBytes {
            throw ProviderError.malformedResponse("response too large")
        }
        // Server error bodies are never treated as transcripts: only parsed `text` is returned.
        return try TranscriptResponseParser.parse(data: data)
    }

    static func classify(urlError: URLError) -> ProviderError {
        switch urlError.code {
        case .timedOut:
            return .timeout
        case .cancelled:
            return .cancelled
        case .httpTooManyRedirects:
            return .redirectBlocked("too many redirects")
        case .redirectToNonExistentLocation:
            return .redirectBlocked("redirect refused")
        case .userAuthenticationRequired, .userCancelledAuthentication:
            return .auth(urlError.localizedDescription)
        case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed,
             .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .cannotLoadFromNetwork:
            return .transport(urlError.localizedDescription)
        default:
            // A refused cross-origin redirect surfaces here on some releases;
            // message mentions redirect only in that case.
            if urlError.localizedDescription.localizedCaseInsensitiveContains("redirect") {
                return .redirectBlocked(urlError.localizedDescription)
            }
            return .transport(urlError.localizedDescription)
        }
    }
}
