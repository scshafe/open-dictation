import Foundation

// MARK: - Multipart transcription contract
//
// POST multipart/form-data to the exact user-configured URL:
//   - `file` part: audio bytes, filename + audio MIME type
//   - `model` field: only when configured
//   - `language` field: only when configured
//   - `Authorization: Bearer ...` header: only when a token is configured
// Success: JSON body with string field `text`.

public struct MultipartFormData {
    public let boundary: String
    private var body = Data()

    public init(boundary: String = MultipartFormData.makeBoundary()) {
        self.boundary = boundary
    }

    public static func makeBoundary() -> String {
        "OpenDictation-\(UUID().uuidString)"
    }

    public var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    public mutating func addField(name: String, value: String) {
        var part = ""
        part += "--\(boundary)\r\n"
        part += "Content-Disposition: form-data; name=\"\(escape(name))\"\r\n\r\n"
        part += "\(value)\r\n"
        body.append(Data(part.utf8))
    }

    public mutating func addFileField(name: String, filename: String, mimeType: String, data: Data) {
        var head = ""
        head += "--\(boundary)\r\n"
        head += "Content-Disposition: form-data; name=\"\(escape(name))\"; filename=\"\(escape(filename))\"\r\n"
        head += "Content-Type: \(mimeType)\r\n\r\n"
        body.append(Data(head.utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    /// Finalize with the closing boundary. Do not append after calling.
    public mutating func finalize() {
        body.append(Data("--\(boundary)--\r\n".utf8))
    }

    public func encode() -> Data { body }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

public enum MultipartRequestBuilder {
    public static let filePartName = "file"
    public static let defaultFilename = "recording.wav"
    public static let defaultMIMEType = "audio/wav"

    /// Build the request body for the transcription contract.
    public static func buildBody(audioData: Data, config: ProviderConfig, boundary: String? = nil) -> (body: Data, contentType: String) {
        var form = MultipartFormData(boundary: boundary ?? MultipartFormData.makeBoundary())
        form.addFileField(
            name: filePartName,
            filename: defaultFilename,
            mimeType: defaultMIMEType,
            data: audioData
        )
        if let model = config.model { form.addField(name: "model", value: model) }
        if let language = config.language { form.addField(name: "language", value: language) }
        form.finalize()
        return (form.encode(), form.contentType)
    }

    /// Build the full URLRequest (headers + body loaded separately by the transport).
    public static func buildRequest(audioData: Data, config: ProviderConfig) -> URLRequest {
        let (body, contentType) = buildBody(audioData: audioData, config: config)
        var request = URLRequest(url: config.endpointURL)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("OpenDictation/1.0", forHTTPHeaderField: "User-Agent")
        if let token = config.bearerToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        return request
    }
}
