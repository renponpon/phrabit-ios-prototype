import Foundation

private final class GuestCheckNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

@MainActor
final class GuestCheckPreviewTransport {
    private let origin: URL
    private var code: String?
    private let session: URLSession
    private let noRedirects = GuestCheckNoRedirects()

    init(origin: URL, code: String) throws {
        guard let parts = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
              let host = parts.host,
              host.range(of: #"\Aphrabit-ios-guest-preview-[a-z0-9]{9,16}-renponpons-projects\.vercel\.app\z"#,
                         options: .regularExpression) != nil,
              origin.absoluteString == "https://" + host + parts.path,
              code.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil else {
            throw GuestDeviceCheckError.unexpectedResponse
        }
        self.origin = origin
        self.code = code
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        session = URLSession(configuration: configuration)
    }

    func request(_ route: GuestCheckJSONAPI.Route, _ body: Data) throws -> URLRequest {
        guard let code, !body.isEmpty, body.count <= 35 * 1024,
              let url = URL(string: route.rawValue, relativeTo: origin)?.absoluteURL else {
            throw GuestDeviceCheckError.unexpectedResponse
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(code, forHTTPHeaderField: "x-phrabit-preview-pass")
        return request
    }

    func send(_ route: GuestCheckJSONAPI.Route, _ body: Data) async throws -> GuestCheckJSONAPI.Reply {
        let request = try request(route, body)
        let (bytes, response) = try await session.bytes(for: request, delegate: noRedirects)
        guard let reply = response as? HTTPURLResponse, reply.url == request.url,
              (200...299).contains(reply.statusCode), reply.mimeType == "application/json" else {
            throw GuestDeviceCheckError.unexpectedResponse
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2_048 else { throw GuestDeviceCheckError.unexpectedResponse }
            data.append(byte)
        }
        return .init(status: reply.statusCode, body: data)
    }

    func close() {
        code = nil
        session.invalidateAndCancel()
    }
}
