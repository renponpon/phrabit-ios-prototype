import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CaptureConnectionCheckError: LocalizedError {
    case signInRequired, unavailable, deploymentProtected, invalidResponse, network

    public var errorDescription: String? {
        switch self {
        case .signInRequired: return "Phrabitにログインしてください。"
        case .unavailable: return "この環境の接続確認はまだ有効になっていません。"
        case .deploymentProtected: return "検証サーバーのアクセス設定を確認してください。再ログインでは解消しません。"
        case .invalidResponse: return "検証環境の応答を確認できませんでした。"
        case .network: return "接続確認に失敗しました。通信が戻ってからお試しください。"
        }
    }
}

@MainActor
public final class CaptureConnectionVerifier {
    public enum PreviewTarget { case account, captureEdge }

    private let endpoint: URL
    private let session: URLSession
    private let access: CaptureAccessController
    private let previewAuthKey: String?
    private let responseContract: String?

    public init(origin: URL, access: CaptureAccessController, protocolClasses: [AnyClass]? = nil) throws {
        guard origin.scheme == "https", origin.host != nil, origin.user == nil, origin.password == nil,
              origin.query == nil, origin.fragment == nil, origin.path.isEmpty || origin.path == "/" else { throw CaptureClientError.invalidConfiguration }
        self.endpoint = origin.appendingPathComponent("api/capture/access")
        self.access = access
        self.session = CaptureHTTPProcessor.makeSession(protocolClasses: protocolClasses, timeout: 10)
        self.previewAuthKey = nil
        self.responseContract = "capture-access-v1"
    }

    public init(previewAuth configuration: CaptureAuthConfiguration, target: PreviewTarget = .account, access: CaptureAccessController, protocolClasses: [AnyClass]? = nil) throws {
        let project = configuration.projectURL
        guard project == configuration.apiOrigin, project.port == nil,
              project.host?.range(of: #"^[a-z]{20}\.supabase\.co$"#, options: .regularExpression) != nil,
              configuration.publishableKey.hasPrefix("sb_publishable_") else { throw CaptureClientError.invalidConfiguration }
        switch target {
        case .account:
            self.endpoint = project.appendingPathComponent("auth/v1/user")
            self.responseContract = nil
        case .captureEdge:
            self.endpoint = project.appendingPathComponent("functions/v1/phrabit-capture-check")
            self.responseContract = "capture-edge-v1"
        }
        self.access = access
        self.session = CaptureHTTPProcessor.makeSession(protocolClasses: protocolClasses, timeout: 10)
        self.previewAuthKey = configuration.publishableKey
    }

    public func verify() async throws {
        try Task.checkCancellation()
        guard access.canRecord, let expectedUser = access.userID else { throw CaptureConnectionCheckError.signInRequired }
        let revision = access.sessionRevision
        let token: String
        do { token = try await access.validAccessToken() }
        catch is CancellationError { throw CancellationError() }
        catch {
            if let failure = error as? CaptureAccessError, case .connection = failure { throw CaptureConnectionCheckError.network }
            throw CaptureConnectionCheckError.signInRequired
        }
        try Task.checkCancellation()
        guard access.canRecord, access.sessionRevision == revision else { throw CancellationError() }
        guard !token.isEmpty, token.count <= 8192, !token.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw CaptureConnectionCheckError.signInRequired }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let previewAuthKey { request.setValue(previewAuthKey, forHTTPHeaderField: "apikey") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard access.canRecord, access.sessionRevision == revision else { throw CancellationError() }
            guard let response = response as? HTTPURLResponse, response.url == endpoint else { throw CaptureConnectionCheckError.invalidResponse }
            if (300...399).contains(response.statusCode) { throw CaptureConnectionCheckError.deploymentProtected }
            guard let responseContract else {
                try Self.validatePreviewAuth(data: data, response: response, expectedUser: expectedUser)
                return
            }
            guard data.count <= 4096,
                  response.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("application/json") == true,
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let requestID = payload["requestId"], UUID(uuidString: requestID) != nil else {
                throw [401, 403].contains(response.statusCode) ? CaptureConnectionCheckError.deploymentProtected : CaptureConnectionCheckError.invalidResponse
            }
            switch response.statusCode {
            case 200:
                guard Set(payload.keys) == Set(["requestId", "status", "environment", "contract"]), payload["status"] == "ready",
                      payload["environment"] == "preview", payload["contract"] == responseContract else { throw CaptureConnectionCheckError.invalidResponse }
            case 401:
                guard payload["code"] == "capture_auth_required" else { throw CaptureConnectionCheckError.deploymentProtected }
                throw CaptureConnectionCheckError.signInRequired
            case 403:
                guard payload["code"] == "capture_unavailable" else { throw CaptureConnectionCheckError.deploymentProtected }
                throw CaptureConnectionCheckError.unavailable
            case 503, 408: throw CaptureConnectionCheckError.network
            default: throw CaptureConnectionCheckError.invalidResponse
            }
        } catch is CancellationError { throw CancellationError() }
        catch let failure as CaptureConnectionCheckError { throw failure }
        catch { if Task.isCancelled { throw CancellationError() }; throw CaptureConnectionCheckError.network }
    }

    private static func validatePreviewAuth(data: Data, response: HTTPURLResponse, expectedUser: UUID) throws {
        if response.statusCode == 429 || (500...599).contains(response.statusCode) { throw CaptureConnectionCheckError.network }
        guard data.count <= 131_072,
              response.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("application/json") == true,
              let payload = try? JSONDecoder().decode(PreviewAuthResponse.self, from: data) else { throw CaptureConnectionCheckError.invalidResponse }
        if response.statusCode == 401, let code = payload.code, ["bad_jwt", "session_not_found", "session_expired"].contains(code) {
            throw CaptureConnectionCheckError.signInRequired
        }
        guard response.statusCode == 200, payload.id == expectedUser, payload.role == "authenticated",
              payload.isAnonymous == false else { throw CaptureConnectionCheckError.invalidResponse }
    }
}

private struct PreviewAuthResponse: Decodable {
    let id: UUID?
    let role: String?
    let isAnonymous: Bool?
    let code: String?

    enum CodingKeys: String, CodingKey {
        case id, role, code
        case isAnonymous = "is_anonymous"
    }
}
