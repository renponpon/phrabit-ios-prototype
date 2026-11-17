import Auth
import Foundation

@MainActor
public final class CaptureSupabaseAuthentication: CaptureAuthenticating {
    public let isMock = false
    public var cachedUserID: UUID? { client.currentSession?.user.id }
    private let configuration: CaptureAuthConfiguration
    private let storage: any CaptureSecureStorage
    private let openBrowser: @MainActor (URL) async throws -> URL
    private let injectedFetch: AuthClient.FetchHandler?
    private var scope: CaptureAuthScope
    private var client: AuthClient
    private var loginID: UUID?

    public init(configuration: CaptureAuthConfiguration, storage: any CaptureSecureStorage,
                fetch: AuthClient.FetchHandler? = nil, openBrowser: @escaping @MainActor (URL) async throws -> URL) {
        self.configuration = configuration
        let storage = CaptureEnvironmentStorage(base: storage, namespace: configuration.environmentID)
        self.storage = storage
        self.openBrowser = openBrowser
        self.injectedFetch = fetch
        let scope = CaptureAuthScope(storage: storage)
        self.scope = scope
        self.client = Self.makeClient(configuration: configuration, scope: scope, fetch: fetch)
    }

    public func signIn() async throws -> UUID {
        guard loginID == nil else { throw CaptureAccessError.authentication }
        try clearLocalSession()
        let identifier = UUID()
        loginID = identifier
        let attemptScope = scope
        let attemptClient = client
        defer { if loginID == identifier { loginID = nil }; attemptScope.endRequest() }
        do {
            let url = try attemptClient.getOAuthSignInURL(provider: .google, redirectTo: CaptureAuthConfiguration.callbackURL)
            guard try attemptScope.retrieve(key: "capture-session-code-verifier") != nil else { throw CaptureAccessError.storage }
            let callback = try await openBrowser(url)
            try Task.checkCancellation()
            guard loginID == identifier else { throw CancellationError() }
            let code = try CaptureAuthConfiguration.authorizationCode(from: callback)
            attemptScope.beginRequest()
            let session = try await attemptClient.exchangeCodeForSession(authCode: code)
            try Task.checkCancellation()
            guard loginID == identifier, cachedUserID == session.user.id,
                  try Self.persisted(session, in: attemptScope) else { throw CaptureAccessError.storage }
            return session.user.id
        } catch {
            if loginID == identifier { try? clearLocalSession() }
            if error is CancellationError { throw CancellationError() }
            throw (error as? CaptureAccessError) ?? CaptureAccessError.authentication
        }
    }

    public func accessToken() async throws -> String {
        guard loginID == nil, client.currentSession != nil else { throw CaptureAccessError.authentication }
        let currentScope = scope
        currentScope.beginRequest()
        defer { currentScope.endRequest() }
        do {
            let result = try await client.session
            try Task.checkCancellation()
            guard currentScope.isActive, cachedUserID == result.user.id,
                  try Self.persisted(result, in: currentScope) else { throw CaptureAccessError.storage }
            return result.accessToken
        } catch is CancellationError { throw CancellationError() }
        catch {
            if let error = error as? CaptureAccessError, case .storage = error { throw error }
            if let error = error as? AuthError, case .api(_, _, _, let response) = error, [400, 401, 403].contains(response.statusCode) { throw CaptureAccessError.authentication }
            if cachedUserID == nil { throw CaptureAccessError.authentication }
            throw CaptureAccessError.connection
        }
    }

    public func clearLocalSession() throws {
        loginID = nil
        scope.invalidate()
        var failure: Error?
        for key in ["capture-session", "capture-session-code-verifier"] {
            do { try storage.remove(key: key) } catch { failure = error }
        }
        let replacement = CaptureAuthScope(storage: storage)
        scope = replacement
        client = Self.makeClient(configuration: configuration, scope: replacement, fetch: injectedFetch)
        if failure != nil { replacement.invalidate(); throw CaptureAccessError.storage }
    }

    private static func persisted(_ session: Session, in scope: CaptureAuthScope) throws -> Bool {
        guard let data = try scope.retrieve(key: "capture-session"), let saved = try? JSONDecoder().decode(Session.self, from: data) else { return false }
        return saved.accessToken == session.accessToken && saved.refreshToken == session.refreshToken
    }

    private static func makeClient(configuration: CaptureAuthConfiguration, scope: CaptureAuthScope, fetch: AuthClient.FetchHandler?) -> AuthClient {
        let session = CaptureAuthHTTPSession.make()
        let project = configuration.projectURL
        let transport: AuthClient.FetchHandler = { request in
            try scope.takeRequest()
            guard request.url?.scheme == project.scheme, request.url?.host == project.host, request.url?.port == project.port,
                  request.url?.path == "/auth/v1/token", request.httpMethod == "POST" else { throw CaptureAccessError.configuration }
            try Task.checkCancellation()
            let response: (Data, URLResponse)
            if let fetch { response = try await fetch(request) }
            else { response = try await session.data(for: request) }
            try Task.checkCancellation()
            guard scope.isActive else { throw CaptureAccessError.cancelled }
            return response
        }
        return AuthClient(url: project.appendingPathComponent("auth/v1"), headers: ["apikey": configuration.publishableKey],
                          flowType: .pkce, redirectToURL: CaptureAuthConfiguration.callbackURL, storageKey: "capture-session",
                          localStorage: scope, logger: nil, fetch: transport, autoRefreshToken: false, emitLocalSessionAsInitialSession: true)
    }
}

private final class CaptureAuthScope: AuthLocalStorage, @unchecked Sendable {
    private let storage: any CaptureSecureStorage
    private let lock = NSLock()
    private var active = true
    private var allowed = false
    private var sent = false
    init(storage: any CaptureSecureStorage) { self.storage = storage }
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    func beginRequest() { lock.lock(); defer { lock.unlock() }; allowed = active; sent = false }
    func endRequest() { lock.lock(); defer { lock.unlock() }; allowed = false }
    func invalidate() { lock.lock(); defer { lock.unlock() }; active = false; allowed = false }
    func takeRequest() throws {
        lock.lock(); defer { lock.unlock() }
        guard active, allowed, !sent else { throw CaptureAccessError.cancelled }
        sent = true
    }
    func store(key: String, value: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard active else { throw CaptureAccessError.cancelled }
        guard ["capture-session", "capture-session-code-verifier"].contains(key) else { throw CaptureAccessError.storage }
        if key == "capture-session" {
            var session = try JSONDecoder().decode(Session.self, from: value)
            session.providerToken = nil
            session.providerRefreshToken = nil
            try storage.store(key: key, value: JSONEncoder().encode(session))
        } else { try storage.store(key: key, value: value) }
    }
    func retrieve(key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard active, ["capture-session", "capture-session-code-verifier"].contains(key) else { return nil }
        return try storage.retrieve(key: key)
    }
    func remove(key: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        if ["capture-session", "capture-session-code-verifier"].contains(key) { try storage.remove(key: key) }
    }
}

private final class CaptureAuthHTTPSession: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static func make() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config, delegate: CaptureAuthHTTPSession(), delegateQueue: nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
