import Foundation
import XCTest
@testable import PhrabitCaptureCore

@MainActor
final class CaptureConnectionDiagnosticsTests: XCTestCase {
    func testNoLoginDoesNotRunTheCheck() async {
        let backend = DiagnosticBackend()
        let access = CaptureAccessController(backend: backend, storage: CaptureMemoryStorage(), environmentID: "check")
        let diagnostics = CaptureConnectionDiagnostics(access: access, check: { XCTFail("ログイン前に診断しました") })
        diagnostics.run()
        await Task.yield()
        if case .failed = diagnostics.state {} else { XCTFail("未認証を受け付けました") }
    }

    func testSuccessAndRepeatedTapOnlyRunOnce() async {
        let access = signedIn()
        let gate = DiagnosticGate()
        var calls = 0
        let diagnostics = CaptureConnectionDiagnostics(access: access, check: { calls += 1; await gate.wait() })
        diagnostics.run()
        diagnostics.run()
        await waitForGate(gate)
        XCTAssertEqual(calls, 1)
        gate.resume()
        await settle(diagnostics)
        XCTAssertEqual(diagnostics.state, .ready)
        XCTAssertTrue(access.canRecord)
    }

    func testNetworkFailureKeepsAuthentication() async {
        await assertKeepsAuthentication(.network)
    }

    func testDeploymentProtectionKeepsAuthentication() async {
        await assertKeepsAuthentication(.deploymentProtected)
    }

    func testServerFeatureOffKeepsAuthentication() async {
        await assertKeepsAuthentication(.unavailable)
    }

    func testOnlyCurrentApplicationAuthenticationFailureSignsOut() async {
        let access = signedIn()
        let diagnostics = CaptureConnectionDiagnostics(access: access, check: { throw CaptureConnectionCheckError.signInRequired })
        diagnostics.run()
        await settle(diagnostics)
        XCTAssertFalse(access.canRecord)
        XCTAssertEqual(access.state, .signedOut)
        XCTAssertTrue(access.consentAccepted)
    }

    func testCancelIgnoresLateSuccessAndKeepsLogin() async {
        let access = signedIn()
        let gate = DiagnosticGate()
        let diagnostics = CaptureConnectionDiagnostics(access: access, check: { await gate.wait() })
        diagnostics.run()
        await waitForGate(gate)
        diagnostics.cancel()
        gate.resume()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(diagnostics.state, .idle)
        XCTAssertTrue(access.canRecord)
    }

    func testOldSuccessDoesNotValidateANewSameUserLogin() async {
        await assertOldResponseIgnored(fails: false)
    }

    func testOldFailureDoesNotClearANewSameUserLogin() async {
        await assertOldResponseIgnored(fails: true)
    }

    func testUnknownFailureIsSanitized() async {
        let diagnostics = CaptureConnectionDiagnostics(access: signedIn(), check: { throw NSError(domain: "private provider response", code: 1, userInfo: [NSLocalizedDescriptionKey: "secret body"]) })
        diagnostics.run()
        await settle(diagnostics)
        if case .failed(let message) = diagnostics.state {
            XCTAssertFalse(message.contains("private"))
            XCTAssertFalse(message.contains("secret"))
        } else { XCTFail("失敗を成功にしました") }
    }

    private func signedIn(_ suppliedBackend: DiagnosticBackend? = nil) -> CaptureAccessController {
        let backend = suppliedBackend ?? DiagnosticBackend()
        let access = CaptureAccessController(backend: backend, storage: CaptureMemoryStorage(), environmentID: "check")
        access.acceptConsent()
        return access
    }

    private func assertKeepsAuthentication(_ failure: CaptureConnectionCheckError) async {
        let access = signedIn()
        let revision = access.sessionRevision
        let diagnostics = CaptureConnectionDiagnostics(access: access, check: { throw failure })
        diagnostics.run()
        await settle(diagnostics)
        if case .failed = diagnostics.state {} else { XCTFail("失敗を成功にしました") }
        XCTAssertTrue(access.canRecord)
        XCTAssertEqual(access.sessionRevision, revision)
    }

    private func assertOldResponseIgnored(fails: Bool) async {
        let backend = DiagnosticBackend()
        let access = signedIn(backend)
        let gate = DiagnosticGate()
        let diagnostics = CaptureConnectionDiagnostics(access: access, check: { await gate.wait(); if fails { throw CaptureConnectionCheckError.signInRequired } })
        diagnostics.run()
        await waitForGate(gate)
        access.clearSession()
        access.signIn()
        for _ in 0..<1000 { if access.canRecord { break }; await Task.yield() }
        XCTAssertTrue(access.canRecord)
        gate.resume()
        await settle(diagnostics)
        XCTAssertEqual(diagnostics.state, .idle)
        XCTAssertTrue(access.canRecord)
    }

    private func settle(_ diagnostics: CaptureConnectionDiagnostics) async {
        for _ in 0..<1000 { if !diagnostics.isBusy { return }; await Task.yield() }
        XCTFail("診断が完了しませんでした")
    }

    private func waitForGate(_ gate: DiagnosticGate) async {
        for _ in 0..<1000 { if gate.isWaiting { return }; await Task.yield() }
        XCTFail("診断が開始しませんでした")
    }
}

@MainActor
private final class DiagnosticBackend: CaptureAuthenticating {
    let isMock = false
    let owner = UUID()
    var cachedUserID: UUID?
    init() { cachedUserID = owner }
    func signIn() async throws -> UUID { cachedUserID = owner; return owner }
    func accessToken() async throws -> String { "synthetic-check" }
    func clearLocalSession() throws { cachedUserID = nil }
}

@MainActor
private final class DiagnosticGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func resume() { let pending = continuation; continuation = nil; pending?.resume() }
}
