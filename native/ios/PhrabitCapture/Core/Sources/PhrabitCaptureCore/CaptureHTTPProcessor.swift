import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor
public final class CaptureHTTPProcessor: CaptureProcessing {
    public let sendsAudio = true
    private let origin: URL
    private let session: URLSession
    private let accessToken: () async throws -> String
    private let consentGranted: () -> Bool

    public init(origin: URL, protocolClasses: [AnyClass]? = nil, consentGranted: @escaping () -> Bool, accessToken: @escaping () async throws -> String) throws {
        guard origin.scheme == "https", origin.host != nil, origin.user == nil, origin.password == nil,
              origin.query == nil, origin.fragment == nil, origin.path.isEmpty || origin.path == "/" else {
            throw CaptureClientError.invalidConfiguration
        }
        self.origin = origin
        self.session = Self.makeSession(protocolClasses: protocolClasses)
        self.consentGranted = consentGranted
        self.accessToken = accessToken
    }

    static func makeSession(protocolClasses: [AnyClass]? = nil, timeout: TimeInterval = 45) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return URLSession(configuration: configuration, delegate: CaptureRedirectBlocker(), delegateQueue: nil)
    }

    public func transcribe(audio: Data, durationMilliseconds: Int, sessionID: UUID) async throws -> String {
        guard !audio.isEmpty, audio.count <= 2 * 1024 * 1024, (250...21_500).contains(durationMilliseconds) else {
            throw CaptureClientError.invalidInput
        }
        let boundary = "Phrabit-\(UUID().uuidString)"
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        for (name, value) in [("sessionId", sessionID.uuidString), ("durationMs", String(durationMilliseconds))] {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"recording.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n")
        body.append(audio)
        append("\r\n--\(boundary)--\r\n")
        let data = try await send(path: "api/capture/transcribe", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
        guard let result = try? JSONDecoder().decode(TranscriptResponse.self, from: data),
              UUID(uuidString: result.sessionId) == sessionID, UUID(uuidString: result.requestId) != nil,
              result.language == "ja", !result.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              result.transcript.utf16.count <= 10_000 else { throw CaptureClientError.invalidResponse }
        return result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func translate(text: String, to language: CaptureLanguage, sessionID: UUID) async throws -> CaptureTranslation {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, source.utf16.count <= 500 else { throw CaptureClientError.invalidInput }
        let body = try JSONEncoder().encode(TranslationRequest(sessionId: sessionID.uuidString, sourceText: source, targetLanguage: language.rawValue))
        let data = try await send(path: "api/capture/translate", body: body, contentType: "application/json")
        guard let result = try? JSONDecoder().decode(TranslationResponse.self, from: data),
              UUID(uuidString: result.sessionId) == sessionID, UUID(uuidString: result.requestId) != nil,
              result.sourceText == source, result.targetLanguage == language.rawValue,
              !result.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              result.targetText.utf16.count <= 10_000 else { throw CaptureClientError.invalidResponse }
        if language == .chinese {
            guard result.readingType == "pinyin", let reading = result.reading, !reading.isEmpty else { throw CaptureClientError.invalidResponse }
        } else if result.reading != nil || result.readingType != nil {
            throw CaptureClientError.invalidResponse
        }
        return CaptureTranslation(sourceText: source, targetText: result.targetText, reading: result.reading, language: language)
    }

    private func send(path: String, body: Data, contentType: String) async throws -> Data {
        try Task.checkCancellation()
        guard consentGranted() else { throw CaptureClientError.unavailable }
        let token: String
        do { token = try await accessToken() }
        catch is CancellationError { throw CancellationError() }
        catch {
            if let error = error as? CaptureAccessError, case .connection = error { throw CaptureClientError.requestFailed }
            throw CaptureClientError.authenticationRequired
        }
        guard !token.isEmpty, token.count <= 8192, !token.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw CaptureClientError.authenticationRequired }
        try Task.checkCancellation()
        guard consentGranted() else { throw CaptureClientError.unavailable }
        var request = URLRequest(url: origin.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = body
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, response.url?.host == origin.host,
                  response.url?.scheme == origin.scheme, response.url?.port == origin.port else { throw CaptureClientError.invalidResponse }
            switch response.statusCode {
            case 200:
                guard data.count <= 131_072, response.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("application/json") == true else { throw CaptureClientError.invalidResponse }
                return data
            case 400, 413: throw CaptureClientError.invalidInput
            case 401:
                guard Self.isCaptureError(data, response: response, code: "capture_auth_required") else { throw CaptureClientError.deploymentProtected }
                throw CaptureClientError.authenticationRequired
            case 403:
                guard Self.isCaptureError(data, response: response, code: "capture_unavailable") else { throw CaptureClientError.deploymentProtected }
                throw CaptureClientError.unavailable
            case 300...399: throw CaptureClientError.deploymentProtected
            case 429: throw CaptureClientError.limited
            case 503: throw CaptureClientError.budgetUnavailable
            default: throw CaptureClientError.requestFailed
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as CaptureClientError { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw CaptureClientError.requestFailed }
    }

    private static func isCaptureError(_ data: Data, response: HTTPURLResponse, code: String) -> Bool {
        guard data.count <= 131_072, response.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("application/json") == true,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], value["code"] as? String == code,
              let identifier = value["requestId"] as? String, UUID(uuidString: identifier) != nil else { return false }
        return true
    }
}

private final class CaptureRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct TranscriptResponse: Decodable {
    let requestId: String
    let sessionId: String
    let transcript: String
    let language: String
}

private struct TranslationRequest: Encodable {
    let sessionId: String
    let sourceText: String
    let targetLanguage: String
}

private struct TranslationResponse: Decodable {
    let requestId: String
    let sessionId: String
    let sourceText: String
    let targetText: String
    let targetLanguage: String
    let reading: String?
    let readingType: String?
}
