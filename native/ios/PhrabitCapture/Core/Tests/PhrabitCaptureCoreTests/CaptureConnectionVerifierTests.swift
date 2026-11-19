import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import PhrabitCaptureCore

@MainActor
final class CaptureConnectionVerifierTests: XCTestCase {
    func testExplicitCheckUsesOnlyABearerGetWithoutPayload() async throws {
        let access = signedIn()
        var requests = 0
        ConnectionCheckStub.handler = { request in
            requests += 1
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/capture/access")
            XCTAssertNil(request.url?.query)
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.httpBodyStream)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-check")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            XCTAssertEqual(request.timeoutInterval, 10)
            return (200, "application/json", try Self.success(), nil)
        }
        try await verifier(access).verify()
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(access.canRecord)
    }

    func testNoConsentDoesNotRequestATokenOrNetwork() async throws {
        let backend = ConnectionCheckBackend()
        let access = CaptureAccessController(backend: backend, storage: CaptureMemoryStorage(), environmentID: "check")
        ConnectionCheckStub.handler = { _ in XCTFail("同意なしで通信しました"); return (500, "application/json", Data(), nil) }
        do { try await verifier(access).verify(); XCTFail("同意なしを受け付けました") }
        catch let failure as CaptureConnectionCheckError { if case .signInRequired = failure {} else { XCTFail("誤ったエラー") } }
        XCTAssertEqual(backend.tokenCalls, 0)
    }

    func testMismatchedEnvironmentVersionAndPersonalFieldsAreRejected() async throws {
        for change in [["environment": "production"], ["contract": "future-version"], ["userId": "private-identifier"], ["status": "not-ready"], ["requestId": "invalid"]] {
            ConnectionCheckStub.handler = { _ in (200, "application/json", try Self.success(changes: change), nil) }
            do { try await verifier(signedIn()).verify(); XCTFail("異なる契約を受け付けました") }
            catch let failure as CaptureConnectionCheckError { if case .invalidResponse = failure {} else { XCTFail("誤ったエラー") } }
        }
    }

    func testProtectionHtmlAndRedirectDoNotClearTheAccount() async throws {
        for status in [302, 401, 403] {
            let access = signedIn()
            var requests = 0
            ConnectionCheckStub.handler = { _ in requests += 1; return (status, "text/html", Data("private login page".utf8), nil) }
            do { try await verifier(access).verify(); XCTFail("外部ログイン画面を受け付けました") }
            catch let failure as CaptureConnectionCheckError {
                if case .deploymentProtected = failure {} else { XCTFail("期限切れと混同しました") }
                XCTAssertFalse(failure.localizedDescription.contains("private login"))
            }
            XCTAssertEqual(requests, 1)
            XCTAssertTrue(access.canRecord)
        }
    }

    func testTypedApplicationErrorsAreDistinguished() async throws {
        for status in [401, 403, 503] {
            let access = signedIn()
            let code = status == 401 ? "capture_auth_required" : status == 403 ? "capture_unavailable" : "capture_auth_check_unavailable"
            ConnectionCheckStub.handler = { _ in (status, "application/json", try JSONSerialization.data(withJSONObject: ["requestId": UUID().uuidString, "status": "unavailable", "code": code]), nil) }
            do { try await verifier(access).verify(); XCTFail("失敗を成功にしました") }
            catch let failure as CaptureConnectionCheckError {
                switch (status, failure) {
                case (401, .signInRequired), (403, .unavailable), (503, .network): break
                default: XCTFail("エラー種別を混同しました")
                }
            }
            XCTAssertTrue(access.canRecord)
        }
    }

    func testForeignResponseAndOversizeBodyAreRejected() async throws {
        for foreign in [true, false] {
            ConnectionCheckStub.handler = { _ in
                let body = foreign ? (try Self.success()) : Data(repeating: 65, count: 4097)
                let responseURL = foreign ? URL(string: "https://foreign.invalid/api/capture/access") : nil
                return (200, "application/json", body, responseURL)
            }
            do { try await verifier(signedIn()).verify(); XCTFail("不正な応答を受け付けました") }
            catch let failure as CaptureConnectionCheckError { if case .invalidResponse = failure {} else { XCTFail("誤ったエラー") } }
        }
    }

    func testBadTokenDoesNotReachNetwork() async throws {
        let backend = ConnectionCheckBackend()
        backend.token = "invalid token"
        let access = signedIn(backend)
        ConnectionCheckStub.handler = { _ in XCTFail("不正tokenで通信しました"); return (500, "application/json", Data(), nil) }
        do { try await verifier(access).verify(); XCTFail("不正tokenを受け付けました") }
        catch let failure as CaptureConnectionCheckError { if case .signInRequired = failure {} else { XCTFail("誤ったエラー") } }
    }

    func testTransientRefreshFailureKeepsTheSession() async throws {
        let backend = ConnectionCheckBackend()
        backend.failure = .connection
        let access = signedIn(backend)
        ConnectionCheckStub.handler = { _ in XCTFail("refresh失敗後に通信しました"); return (500, "application/json", Data(), nil) }
        do { try await verifier(access).verify(); XCTFail("通信失敗を受け付けました") }
        catch let failure as CaptureConnectionCheckError { if case .network = failure {} else { XCTFail("誤ったエラー") } }
        XCTAssertTrue(access.canRecord)
    }

    func testPreCancelledCheckDoesNotSend() async throws {
        let access = signedIn()
        let client = try verifier(access)
        ConnectionCheckStub.handler = { _ in XCTFail("取消後に送信しました"); return (500, "application/json", Data(), nil) }
        let task = Task { try await client.verify() }
        task.cancel()
        do { try await task.value; XCTFail("取消を無視しました") } catch is CancellationError {}
        XCTAssertTrue(access.canRecord)
    }

    func testUnsafeOriginsAreRejected() {
        let access = signedIn()
        for value in ["http://preview.invalid", "https://user:password@preview.invalid", "https://preview.invalid/path", "https://preview.invalid?key=value", "https://preview.invalid#token"] {
            XCTAssertThrowsError(try CaptureConnectionVerifier(origin: URL(string: value)!, access: access))
        }
    }

    func testPreviewAuthChecksOnlyCurrentUserWithoutAudio() async throws {
        let access = signedIn()
        let owner = try XCTUnwrap(access.userID)
        let key = "sb_publishable_synthetic_example"
        let configuration = try previewConfiguration(key: key)
        var requests = 0
        ConnectionCheckStub.handler = { request in
            requests += 1
            XCTAssertEqual(request.url, configuration.projectURL.appendingPathComponent("auth/v1/user"))
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-check")
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), key)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.httpBodyStream)
            let body: [String: Any] = ["id": owner.uuidString, "role": "authenticated", "is_anonymous": false, "email": "synthetic"]
            return (200, "application/json", try JSONSerialization.data(withJSONObject: body), nil)
        }
        let client = try CaptureConnectionVerifier(previewAuth: configuration, access: access, protocolClasses: [ConnectionCheckStub.self])
        try await client.verify()
        XCTAssertEqual(requests, 1)
    }

    func testPreviewAuthRejectsDifferentUserAnonymousOrWrongRole() async throws {
        let access = signedIn()
        let owner = try XCTUnwrap(access.userID)
        let configuration = try previewConfiguration()
        let client = try CaptureConnectionVerifier(previewAuth: configuration, access: access, protocolClasses: [ConnectionCheckStub.self])
        let payloads: [[String: Any]] = [
            ["id": UUID().uuidString, "role": "authenticated", "is_anonymous": false],
            ["id": owner.uuidString, "role": "authenticated", "is_anonymous": true],
            ["id": owner.uuidString, "role": "anon", "is_anonymous": false],
            ["id": owner.uuidString, "role": "authenticated"],
        ]
        for payload in payloads {
            ConnectionCheckStub.handler = { _ in
                (200, "application/json", try JSONSerialization.data(withJSONObject: payload), nil)
            }
            do { try await client.verify(); XCTFail("別の利用者または未認証の確認が成功しました") }
            catch let failure as CaptureConnectionCheckError { if case .invalidResponse = failure {} else { XCTFail("誤ったエラー") } }
        }
        XCTAssertTrue(access.canRecord)
    }

    func testPreviewEdgeMakesOnePayloadFreeGetToTheSameProject() async throws {
        let access = signedIn()
        let configuration = try previewConfiguration()
        var requests = 0
        ConnectionCheckStub.handler = { request in
            requests += 1
            XCTAssertEqual(request.url, configuration.projectURL.appendingPathComponent("functions/v1/phrabit-capture-check"))
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-check")
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), configuration.publishableKey)
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.httpBodyStream)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            return (200, "application/json", try Self.success(changes: ["contract": "capture-edge-v1"]), nil)
        }
        let client = try CaptureConnectionVerifier(previewAuth: configuration, target: .captureEdge, access: access, protocolClasses: [ConnectionCheckStub.self])
        try await client.verify()
        XCTAssertEqual(requests, 1)
    }

    func testPreviewEdgeDoesNotAcceptAnAuthOrVercelResponseAsProof() async throws {
        let access = signedIn()
        let owner = try XCTUnwrap(access.userID)
        let client = try CaptureConnectionVerifier(previewAuth: previewConfiguration(), target: .captureEdge, access: access, protocolClasses: [ConnectionCheckStub.self])
        let account = ["id": owner.uuidString, "role": "authenticated"]
        for data in [try JSONSerialization.data(withJSONObject: account), try Self.success(),
                     try Self.success(changes: ["contract": "capture-audio-preview-v1"])] {
            ConnectionCheckStub.handler = { _ in (200, "application/json", data, nil) }
            do { try await client.verify(); XCTFail("別のAPIを検証用APIとして受け付けました") }
            catch let failure as CaptureConnectionCheckError { if case .invalidResponse = failure {} else { XCTFail("誤ったエラー") } }
        }
        XCTAssertTrue(access.canRecord)
    }

    func testPreviewAudioProofUsesAPayloadFreeGetAndRejectsMockProof() async throws {
        let access = signedIn()
        let configuration = try previewConfiguration()
        let client = try CaptureConnectionVerifier(previewAuth: configuration, target: .captureAudio, access: access, protocolClasses: [ConnectionCheckStub.self])
        for contract in ["capture-edge-v1", "capture-audio-preview-v1"] {
            ConnectionCheckStub.handler = { request in
                XCTAssertEqual(request.url, configuration.projectURL.appendingPathComponent("functions/v1/phrabit-capture-audio/access"))
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertNil(request.httpBody)
                XCTAssertNil(request.httpBodyStream)
                return (200, "application/json", try Self.success(changes: ["contract": contract]), nil)
            }
            do {
                try await client.verify()
                XCTAssertEqual(contract, "capture-audio-preview-v1")
            } catch let failure as CaptureConnectionCheckError {
                XCTAssertEqual(contract, "capture-edge-v1")
                if case .invalidResponse = failure {} else { XCTFail("誤ったエラー") }
            }
        }
    }

    func testPreviewAuthRejectsNonSupabaseHostOrDifferentOrigin() throws {
        let access = signedIn()
        let home = try previewConfiguration()
        let unrelated = URL(string: "https://preview.invalid")!
        let mismatch = try CaptureAuthConfiguration(apiOrigin: unrelated, projectURL: home.projectURL, publishableKey: home.publishableKey)
        let foreign = try CaptureAuthConfiguration(apiOrigin: unrelated, projectURL: unrelated, publishableKey: home.publishableKey)
        XCTAssertThrowsError(try CaptureConnectionVerifier(previewAuth: mismatch, access: access))
        XCTAssertThrowsError(try CaptureConnectionVerifier(previewAuth: foreign, access: access))
    }

    func testPreviewAuthErrorsDoNotTreatArbitrary401AsExpiredSession() async throws {
        let access = signedIn()
        let client = try CaptureConnectionVerifier(previewAuth: previewConfiguration(), access: access, protocolClasses: [ConnectionCheckStub.self])
        for (status, code) in [(401, "bad_jwt"), (401, "invalid_api_key"), (429, "rate_limited"), (503, "unavailable")] {
            ConnectionCheckStub.handler = { _ in (status, "application/json", try JSONSerialization.data(withJSONObject: ["code": code]), nil) }
            do { try await client.verify(); XCTFail("失敗を成功にしました") }
            catch let failure as CaptureConnectionCheckError {
                switch (status, code, failure) {
                case (401, "bad_jwt", .signInRequired), (401, "invalid_api_key", .invalidResponse), (429, _, .network), (503, _, .network): break
                default: XCTFail("誤ったエラー")
                }
            }
        }
        XCTAssertTrue(access.canRecord)
    }

    private func previewConfiguration(key: String = "sb_publishable_synthetic_example") throws -> CaptureAuthConfiguration {
        let project = URL(string: "https://abcdefghijklmnopqrst.supabase.co")!
        return try CaptureAuthConfiguration(apiOrigin: project, projectURL: project, publishableKey: key)
    }

    private func signedIn(_ suppliedBackend: ConnectionCheckBackend? = nil) -> CaptureAccessController {
        let backend = suppliedBackend ?? ConnectionCheckBackend()
        let access = CaptureAccessController(backend: backend, storage: CaptureMemoryStorage(), environmentID: "check")
        access.acceptConsent()
        return access
    }

    private func verifier(_ access: CaptureAccessController) throws -> CaptureConnectionVerifier {
        try CaptureConnectionVerifier(origin: URL(string: "https://preview.invalid")!, access: access, protocolClasses: [ConnectionCheckStub.self])
    }

    nonisolated private static func success(changes: [String: String] = [:]) throws -> Data {
        var value = ["requestId": UUID().uuidString, "status": "ready", "environment": "preview", "contract": "capture-access-v1"]
        value.merge(changes) { _, updated in updated }
        return try JSONSerialization.data(withJSONObject: value)
    }
}

@MainActor
private final class ConnectionCheckBackend: CaptureAuthenticating {
    let isMock = false
    var cachedUserID: UUID? = UUID()
    var token = "synthetic-check"
    var tokenCalls = 0
    var failure: CaptureAccessError?
    func signIn() async throws -> UUID { if let cachedUserID { return cachedUserID }; throw CaptureAccessError.authentication }
    func accessToken() async throws -> String { tokenCalls += 1; if let failure { throw failure }; return token }
    func clearLocalSession() throws { cachedUserID = nil }
}

private final class ConnectionCheckStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String, Data, URL?))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler, let originalURL = request.url else { throw URLError(.badURL) }
            let (status, contentType, data, alternateURL) = try handler(request)
            let response = HTTPURLResponse(url: alternateURL ?? originalURL, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": contentType, "Cache-Control": "no-store"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
