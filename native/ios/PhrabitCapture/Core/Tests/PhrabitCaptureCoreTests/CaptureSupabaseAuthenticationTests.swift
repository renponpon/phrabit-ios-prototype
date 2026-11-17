import Foundation
import XCTest
@testable import PhrabitCaptureCore

@MainActor
final class CaptureSupabaseAuthenticationTests: XCTestCase {
    func testSDKCreatesPKCEAndPersistsSessionWithoutExtraRequest() async throws {
        let configuration = try config()
        let storage = CaptureMemoryStorage()
        let probe = AuthNetworkProbe()
        let backend = CaptureSupabaseAuthentication(configuration: configuration, storage: storage, fetch: { request in
            probe.record()
            XCTAssertEqual(request.url?.path, "/auth/v1/token")
            XCTAssertEqual(request.url?.query, "grant_type=pkce")
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
            XCTAssertEqual(payload["auth_code"], "synthetic-code")
            XCTAssertGreaterThan(payload["code_verifier"]?.count ?? 0, 40)
            return try Self.response(request)
        }, openBrowser: { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(items.first { $0.name == "provider" }?.value, "google")
            XCTAssertEqual(items.first { $0.name == "code_challenge_method" }?.value, "s256")
            XCTAssertEqual(items.first { $0.name == "redirect_to" }?.value, CaptureAuthConfiguration.callbackURL.absoluteString)
            return Self.callback()
        })
        XCTAssertNil(backend.cachedUserID)
        XCTAssertEqual(probe.count, 0)
        let user = try await backend.signIn()
        XCTAssertEqual(backend.cachedUserID, user)
        let token = try await backend.accessToken()
        XCTAssertEqual(token, "synthetic-access-token")
        XCTAssertEqual(probe.count, 1)
        let scoped = CaptureEnvironmentStorage(base: storage, namespace: configuration.environmentID)
        let persisted = try XCTUnwrap(try scoped.retrieve(key: "capture-session"))
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains("synthetic-google"))
        XCTAssertNil(try scoped.retrieve(key: "capture-session-code-verifier"))
        try backend.clearLocalSession()
        XCTAssertNil(backend.cachedUserID)
        XCTAssertNil(try scoped.retrieve(key: "capture-session"))
    }

    func testWrongCallbackNeverExchangesCode() async throws {
        let probe = AuthNetworkProbe()
        let backend = CaptureSupabaseAuthentication(configuration: try config(), storage: CaptureMemoryStorage(), fetch: { request in probe.record(); return try Self.response(request) }, openBrowser: { _ in URL(string: "other://auth/callback?code=synthetic")! })
        do { _ = try await backend.signIn(); XCTFail("不正な戻り先を受け付けました") } catch {}
        XCTAssertEqual(probe.count, 0)
        XCTAssertNil(backend.cachedUserID)
    }

    func testFailedAuthenticationDoesNotPerformAnExternalRetry() async throws {
        let probe = AuthNetworkProbe()
        let backend = CaptureSupabaseAuthentication(configuration: try config(), storage: CaptureMemoryStorage(), fetch: { request in
            probe.record()
            return (Data("{\"message\":\"unavailable\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }, openBrowser: { _ in Self.callback() })
        do { _ = try await backend.signIn(); XCTFail("認証失敗を見落としました") } catch {}
        XCTAssertEqual(probe.count, 1)
        XCTAssertNil(backend.cachedUserID)
    }

    func testClearedSessionCannotBeRestoredByLateExchange() async throws {
        let storage = CaptureMemoryStorage()
        let probe = AuthNetworkProbe()
        let configuration = try config()
        let backend = CaptureSupabaseAuthentication(configuration: configuration, storage: storage, fetch: { request in
            probe.record()
            await probe.wait()
            return try Self.response(request)
        }, openBrowser: { _ in Self.callback() })
        let login = Task { try await backend.signIn() }
        for _ in 0..<200 { if probe.isWaiting { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(probe.isWaiting)
        try backend.clearLocalSession()
        probe.resume()
        do { _ = try await login.value; XCTFail("遅れた応答でログインが復活しました") } catch {}
        XCTAssertNil(backend.cachedUserID)
        let scoped = CaptureEnvironmentStorage(base: storage, namespace: configuration.environmentID)
        XCTAssertNil(try scoped.retrieve(key: "capture-session"))
    }

    func testPersistFailureCannotPretendToBeSignedIn() async throws {
        let backend = CaptureSupabaseAuthentication(configuration: try config(), storage: AuthSessionWriteFailure(), fetch: { try Self.response($0) }, openBrowser: { _ in Self.callback() })
        do { _ = try await backend.signIn(); XCTFail("保存できないログインを完了扱いしました") } catch {}
        XCTAssertNil(backend.cachedUserID)
    }

    private func config() throws -> CaptureAuthConfiguration {
        try CaptureAuthConfiguration(apiOrigin: URL(string: "https://api.invalid")!, projectURL: URL(string: "https://auth.invalid")!, publishableKey: "sb_publishable_test")
    }

    nonisolated private static func callback() -> URL { URL(string: CaptureAuthConfiguration.callbackURL.absoluteString + "?code=synthetic-code")! }
    nonisolated private static func response(_ request: URLRequest) throws -> (Data, URLResponse) {
        let user: [String: Any] = ["id": "11111111-1111-4111-8111-111111111111", "aud": "authenticated", "app_metadata": [:], "user_metadata": [:], "is_anonymous": false, "created_at": "2026-11-18T00:00:00Z", "updated_at": "2026-11-18T00:00:00Z"]
        let value: [String: Any] = ["access_token": "synthetic-access-token", "refresh_token": "synthetic-refresh-token", "provider_token": "synthetic-google-access", "provider_refresh_token": "synthetic-google-refresh", "token_type": "bearer", "expires_in": 3600, "expires_at": Date().timeIntervalSince1970 + 3600, "user": user]
        return (try JSONSerialization.data(withJSONObject: value), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
}

private final class AuthNetworkProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var isWaiting: Bool { lock.lock(); defer { lock.unlock() }; return continuation != nil }
    func record() { lock.lock(); defer { lock.unlock() }; calls += 1 }
    func wait() async { await withCheckedContinuation { value in lock.lock(); continuation = value; lock.unlock() } }
    func resume() { lock.lock(); let pending = continuation; continuation = nil; lock.unlock(); pending?.resume() }
}

private final class AuthSessionWriteFailure: CaptureSecureStorage, @unchecked Sendable {
    private let base = CaptureMemoryStorage()
    func store(key: String, value: Data) throws {
        if key.hasSuffix(":capture-session") { throw CaptureAccessError.storage }
        try base.store(key: key, value: value)
    }
    func retrieve(key: String) throws -> Data? { try base.retrieve(key: key) }
    func remove(key: String) throws { try base.remove(key: key) }
}
