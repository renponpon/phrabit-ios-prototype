import Foundation
import XCTest
@testable import PhrabitCaptureCore

@MainActor
final class CaptureAccessTests: XCTestCase {
    func testNoConsentMeansNoAuthenticationOrRecording() async {
        let backend = AccessTestBackend()
        let access = CaptureAccessController(backend: backend, storage: CaptureMemoryStorage(), environmentID: "test")
        access.signIn()
        await Task.yield()
        XCTAssertEqual(backend.signIns, 0)
        XCTAssertFalse(access.canRecord)
        XCTAssertEqual(access.state, .consentRequired)
    }

    func testConsentAndLoginAreSeparateSteps() async {
        let backend = AccessTestBackend()
        let access = CaptureAccessController(backend: backend, storage: CaptureMemoryStorage(), environmentID: "test")
        access.acceptConsent()
        XCTAssertEqual(access.state, .signedOut)
        XCTAssertFalse(access.canRecord)
        access.signIn()
        access.signIn()
        await settle(access)
        XCTAssertEqual(backend.signIns, 1)
        XCTAssertEqual(access.state, .signedIn)
        XCTAssertTrue(access.canRecord)
    }

    func testConsentIsEnvironmentScopedAndRevocationPersists() async {
        let storage = CaptureMemoryStorage()
        let backend = AccessTestBackend()
        let first = CaptureAccessController(backend: backend, storage: storage, environmentID: "preview-a")
        first.acceptConsent()
        first.signIn()
        await settle(first)
        let other = CaptureAccessController(backend: backend, storage: storage, environmentID: "preview-b")
        XCTAssertFalse(other.consentAccepted)
        XCTAssertFalse(other.canRecord)
        first.withdrawConsent()
        XCTAssertFalse(first.canRecord)
        XCTAssertNil(backend.cachedUserID)
        let restored = CaptureAccessController(backend: backend, storage: storage, environmentID: "preview-a")
        XCTAssertEqual(restored.state, .consentRequired)
    }

    func testStorageFailureCannotEnableConsent() {
        let access = CaptureAccessController(backend: AccessTestBackend(), storage: AccessFailingStorage(), environmentID: "test")
        access.acceptConsent()
        XCTAssertFalse(access.consentAccepted)
        XCTAssertFalse(access.canRecord)
        if case .failed = access.state {} else { XCTFail("保存失敗を見落としました") }
    }

    func testLocalRecordingRequiresASeparateOwnerCheckWithoutRefreshingAtStart() throws {
        let backend = AccessTestBackend()
        backend.cachedUserID = backend.identifier
        let access = CaptureAccessController(backend: backend, storage: CaptureMemoryStorage(), environmentID: "preview", allowsVerifiedLocalRecording: true)
        XCTAssertThrowsError(try access.confirmLocalRecording(afterCheckFor: access.sessionRevision))
        access.acceptConsent()
        XCTAssertTrue(access.canRecord)
        XCTAssertFalse(access.canRecordLocally)
        try access.confirmLocalRecording(afterCheckFor: access.sessionRevision)
        XCTAssertTrue(access.canRecordLocally)
        XCTAssertEqual(backend.tokenRequests, 0)
    }

    func testAudioPilotCannotUseUntimedProofAndExpiresAcrossRelaunch() throws {
        let backend = AccessTestBackend()
        backend.cachedUserID = backend.identifier
        let storage = CaptureMemoryStorage()
        var now = Date(timeIntervalSince1970: 1000)
        func controller() -> CaptureAccessController {
            CaptureAccessController(backend: backend, storage: storage, environmentID: "pilot", allowsVerifiedLocalRecording: true,
                                    requiresPilotDeadline: true, now: { now })
        }
        let access = controller()
        access.acceptConsent()
        XCTAssertThrowsError(try access.confirmLocalRecording(afterCheckFor: access.sessionRevision))
        XCTAssertThrowsError(try access.confirmLocalRecording(afterCheckFor: access.sessionRevision, until: now.addingTimeInterval(901)))
        XCTAssertFalse(access.canRecordLocally)
        try access.confirmLocalRecording(afterCheckFor: access.sessionRevision, until: now.addingTimeInterval(60))
        XCTAssertTrue(access.canRecordLocally)
        XCTAssertTrue(controller().canRecordLocally)
        now = now.addingTimeInterval(60)
        XCTAssertFalse(access.canRecordLocally)
        XCTAssertFalse(controller().canRecordLocally)
        XCTAssertTrue(access.canRecord)
        XCTAssertEqual(backend.tokenRequests, 0)
    }

    func testLocalOwnerProofRestoresOnlyForTheSameUserAndPreview() throws {
        let storage = CaptureMemoryStorage()
        let backend = AccessTestBackend()
        backend.cachedUserID = backend.identifier
        let first = CaptureAccessController(backend: backend, storage: storage, environmentID: "preview", allowsVerifiedLocalRecording: true)
        first.acceptConsent()
        try first.confirmLocalRecording(afterCheckFor: first.sessionRevision)
        XCTAssertTrue(CaptureAccessController(backend: backend, storage: storage, environmentID: "preview", allowsVerifiedLocalRecording: true).canRecordLocally)
        XCTAssertFalse(CaptureAccessController(backend: backend, storage: storage, environmentID: "preview").canRecordLocally)
        XCTAssertFalse(CaptureAccessController(backend: backend, storage: storage, environmentID: "other", allowsVerifiedLocalRecording: true).canRecordLocally)
        backend.cachedUserID = UUID()
        XCTAssertFalse(CaptureAccessController(backend: backend, storage: storage, environmentID: "preview", allowsVerifiedLocalRecording: true).canRecordLocally)
    }

    func testLogoutAndReSignInDoNotReuseAnEarlierOwnerCheck() async throws {
        let storage = CaptureMemoryStorage()
        let backend = AccessTestBackend()
        let access = CaptureAccessController(backend: backend, storage: storage, environmentID: "preview", allowsVerifiedLocalRecording: true)
        access.acceptConsent()
        access.signIn()
        await settle(access)
        let oldRevision = access.sessionRevision
        try access.confirmLocalRecording(afterCheckFor: oldRevision)
        access.clearSession()
        XCTAssertFalse(access.canRecordLocally)
        access.signIn()
        await settle(access)
        XCTAssertEqual(access.userID, backend.identifier)
        XCTAssertThrowsError(try access.confirmLocalRecording(afterCheckFor: oldRevision))
        XCTAssertFalse(access.canRecordLocally)
        try access.confirmLocalRecording(afterCheckFor: access.sessionRevision)
        access.withdrawConsent()
        XCTAssertFalse(access.canRecordLocally)
        XCTAssertFalse(CaptureAccessController(backend: backend, storage: storage, environmentID: "preview", allowsVerifiedLocalRecording: true).canRecordLocally)
    }

    func testLocalMockReturnsBothFixedResultsWithoutReadingAudio() async throws {
        let processor = MockCaptureProcessor()
        let sessionID = UUID()
        XCTAssertFalse(processor.sendsAudio)
        let recognizedText = try await processor.transcribe(audio: Data(), durationMilliseconds: 400, sessionID: sessionID)
        for language in CaptureLanguage.allCases {
            let result = try await processor.translate(text: recognizedText, to: language, sessionID: sessionID)
            XCTAssertEqual(result, MockTranslator.sample(for: language))
        }
    }

    func testConcurrentTokenRequestsShareOneRefresh() async throws {
        let backend = AccessTestBackend()
        let access = CaptureAccessController(backend: backend, storage: CaptureMemoryStorage(), environmentID: "test")
        access.acceptConsent()
        access.signIn()
        await settle(access)
        let first = Task { try await access.validAccessToken() }
        let second = Task { try await access.validAccessToken() }
        let firstToken = try await first.value
        let secondToken = try await second.value
        XCTAssertEqual(firstToken, secondToken)
        XCTAssertEqual(backend.tokenRequests, 1)
    }

    func testLateRefreshCannotClearANewerLoginForTheSameUser() async throws {
        let backend = AccessTestBackend()
        backend.delayToken = true
        let access = CaptureAccessController(backend: backend, storage: CaptureMemoryStorage(), environmentID: "test")
        access.acceptConsent()
        access.signIn()
        await settle(access)
        let old = Task { try await access.validAccessToken() }
        for _ in 0..<1000 { if backend.pendingToken != nil { break }; await Task.yield() }
        XCTAssertNotNil(backend.pendingToken)
        access.clearSession()
        access.signIn()
        await settle(access)
        backend.pendingToken?.resume(returning: "old-token")
        backend.pendingToken = nil
        do { _ = try await old.value; XCTFail("古いセッションを受け付けました") } catch {}
        XCTAssertEqual(access.state, .signedIn)
        XCTAssertEqual(access.userID, backend.identifier)
    }

    func testCancelAndLogoutKeepRecordingDisabled() async {
        let access = CaptureAccessController.mock()
        access.acceptConsent()
        access.signIn()
        access.cancelSignIn()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(access.state, .signedOut)
        XCTAssertFalse(access.canRecord)
        XCTAssertTrue(access.consentAccepted)
    }

    func testCancelledCaptureDoesNotLogOutAValidSession() async throws {
        let backend = AccessTestBackend()
        backend.delayToken = true
        let access = CaptureAccessController(backend: backend, storage: CaptureMemoryStorage(), environmentID: "test")
        access.acceptConsent()
        access.signIn()
        await settle(access)
        let request = Task { try await access.validAccessToken() }
        for _ in 0..<1000 { if backend.pendingToken != nil { break }; await Task.yield() }
        request.cancel()
        backend.pendingToken?.resume(returning: "current-token")
        backend.pendingToken = nil
        do { _ = try await request.value; XCTFail("取消を無視しました") } catch is CancellationError {} catch { XCTFail("取消ではないエラーです") }
        XCTAssertTrue(access.canRecord)
        XCTAssertEqual(access.userID, backend.identifier)
    }

    func testTemporaryRefreshFailureDoesNotDiscardLogin() async {
        let backend = AccessTestBackend()
        backend.connectionFailure = true
        let access = CaptureAccessController(backend: backend, storage: CaptureMemoryStorage(), environmentID: "test")
        access.acceptConsent()
        access.signIn()
        await settle(access)
        do { _ = try await access.validAccessToken(); XCTFail("通信失敗を見落としました") } catch {}
        XCTAssertTrue(access.canRecord)
        XCTAssertEqual(access.userID, backend.identifier)
    }

    func testCallbackRejectsImplicitTokensWrongOriginAndDuplicateCodes() throws {
        let base = CaptureAuthConfiguration.callbackURL.absoluteString
        XCTAssertEqual(try CaptureAuthConfiguration.authorizationCode(from: URL(string: base + "?code=single-use")!), "single-use")
        for value in ["other://auth/callback?code=one", "com.phrabit.app://other/callback?code=one", "com.phrabit.app://auth/other?code=one", base + "?code=one&code=two", base + "?code=one#access_token=token", base + "?access_token=token", base + "?code="] {
            XCTAssertThrowsError(try CaptureAuthConfiguration.authorizationCode(from: URL(string: value)!))
        }
    }

    func testConfigurationRejectsServerSecretsAndNonOriginURLs() {
        let origin = URL(string: "https://api.invalid")!
        let project = URL(string: "https://auth.invalid")!
        XCTAssertThrowsError(try CaptureAuthConfiguration(apiOrigin: origin, projectURL: project, publishableKey: "sb_secret_do-not-use"))
        XCTAssertThrowsError(try CaptureAuthConfiguration(apiOrigin: URL(string: "http://api.invalid")!, projectURL: project, publishableKey: "sb_publishable_test"))
        XCTAssertThrowsError(try CaptureAuthConfiguration(apiOrigin: origin, projectURL: URL(string: "https://auth.invalid/path")!, publishableKey: "sb_publishable_test"))
        XCTAssertNoThrow(try CaptureAuthConfiguration(apiOrigin: origin, projectURL: project, publishableKey: "sb_publishable_test"))
    }

    private func settle(_ access: CaptureAccessController) async {
        for _ in 0..<1000 { if !access.isBusy { return }; await Task.yield() }
        XCTFail("模擬ログインが終了しませんでした")
    }
}

@MainActor
private final class AccessTestBackend: CaptureAuthenticating {
    let isMock = true
    let identifier = UUID()
    var cachedUserID: UUID?
    var signIns = 0
    var tokenRequests = 0
    var delayToken = false
    var connectionFailure = false
    var pendingToken: CheckedContinuation<String, Never>?
    func signIn() async throws -> UUID { signIns += 1; cachedUserID = identifier; return identifier }
    func accessToken() async throws -> String {
        tokenRequests += 1
        if connectionFailure { throw CaptureAccessError.connection }
        if delayToken { return await withCheckedContinuation { pendingToken = $0 } }
        await Task.yield()
        return "synthetic-token"
    }
    func clearLocalSession() throws { cachedUserID = nil }
}

private struct AccessFailingStorage: CaptureSecureStorage {
    func store(key: String, value: Data) throws { throw CaptureAccessError.storage }
    func retrieve(key: String) throws -> Data? { nil }
    func remove(key: String) throws {}
}
