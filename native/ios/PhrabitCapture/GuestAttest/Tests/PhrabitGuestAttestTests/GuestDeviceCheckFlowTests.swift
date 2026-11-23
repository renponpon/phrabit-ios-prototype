import Foundation
import XCTest
@testable import PhrabitGuestAttest

final class GuestDeviceCheckFlowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_799_999_900)
    private let challengeId = "f2d08d31-21ec-4442-a325-2e69469a3ba2"
    private let nonce = String(repeating: "ab", count: 32)
    private let fingerprint = String(repeating: "cd", count: 32)

    @MainActor
    func testRegistrationAndReopenedAppUseOneKeyWithTwoDifferentHashes() async throws {
        let provider = TestProvider()
        let store = TestKeyStore()
        let api = TestEndpoint(first: challenge(offset: 45), second: challenge(offset: 60, isConfirmation: true))
        let wire = GuestCheckJSONAPI(exchange: api.send)
        let first = GuestDeviceCheckFlow(provider: provider, keyStore: store, api: wire, now: { self.now })
        do {
            try await first.enroll()
            XCTFail("The device must prepare and pin an existing key first")
        } catch {
            XCTAssertEqual(error as? GuestDeviceCheckError, .unsupportedKeyState)
        }
        let prepared = try await first.prepare()
        let repeated = try await first.prepare()
        XCTAssertEqual(prepared, fingerprint)
        XCTAssertEqual(repeated, fingerprint)
        XCTAssertEqual(provider.created, 1)
        XCTAssertTrue(api.requests.isEmpty)
        try await first.enroll()
        XCTAssertEqual(store.key?.phase, .registered)

        let reopened = GuestDeviceCheckFlow(provider: provider, keyStore: store, api: wire, now: { self.now })
        try await reopened.confirm()
        XCTAssertEqual(provider.created, 1)
        XCTAssertEqual(provider.attestedKeys, [provider.identifier])
        XCTAssertEqual(provider.assertedKeys, [provider.identifier])
        XCTAssertEqual(api.requests.map(\.route), [.challenge, .register, .challenge, .confirm])
        XCTAssertEqual(api.requests[0].object, ["purpose": "register", "keyHash": fingerprint])
        XCTAssertEqual(api.requests[2].object, ["purpose": "device-check", "keyHash": fingerprint])
        XCTAssertEqual(api.requests[1].object["challengeId"], challengeId)
        XCTAssertEqual(api.requests[1].object["keyHash"], fingerprint)
        XCTAssertEqual(api.requests[3].object["challengeId"], String(challengeId.dropLast()) + "3")
        XCTAssertEqual(api.requests[3].object["keyHash"], fingerprint)
        XCTAssertEqual(Set(api.requests[3].object.keys), Set(["challengeId", "keyHash", "proof"]))
        XCTAssertNotEqual(provider.attestedDigest, provider.assertedDigest)
    }

    @MainActor
    func testLostRegistrationReplyCannotCauseAutomaticReattestationOrReplacement() async throws {
        let provider = TestProvider()
        let store = TestKeyStore()
        let api = TestEndpoint(first: challenge(offset: 45), second: challenge(offset: 60, isConfirmation: true))
        api.dropRegistrationReply = true
        let wire = GuestCheckJSONAPI(exchange: api.send)
        let initial = GuestDeviceCheckFlow(provider: provider, keyStore: store, api: wire, now: { self.now })
        _ = try await initial.prepare()
        do {
            try await initial.enroll()
            XCTFail("The registration reply was lost")
        } catch {}
        XCTAssertEqual(store.key?.phase, .awaitingConfirmation)

        let reopened = GuestDeviceCheckFlow(provider: provider, keyStore: store, api: wire, now: { self.now })
        do {
            try await reopened.enroll()
            XCTFail("Enrollment must not generate a replacement key")
        } catch {
            XCTAssertEqual(error as? GuestDeviceCheckError, .confirmationRequired)
        }
        try await reopened.confirm()
        XCTAssertEqual(store.key?.phase, .registered)
        XCTAssertEqual(provider.created, 1)
        XCTAssertEqual(provider.attestedKeys.count, 1)
    }

    @MainActor
    func testExpiredChallengeDoesNotAskAppleToAttest() async throws {
        let provider = TestProvider()
        let store = TestKeyStore()
        let api = TestEndpoint(first: challenge(offset: -1), second: challenge(offset: 60, isConfirmation: true))
        let wire = GuestCheckJSONAPI(exchange: api.send)
        let flow = GuestDeviceCheckFlow(provider: provider, keyStore: store, api: wire, now: { self.now })
        _ = try await flow.prepare()
        do {
            try await flow.enroll()
            XCTFail("An expired challenge must fail closed")
        } catch {
            XCTAssertEqual(error as? GuestDeviceCheckError, .invalidChallenge)
        }
        XCTAssertEqual(store.key?.phase, .allocated)
        XCTAssertTrue(provider.attestedKeys.isEmpty)
        XCTAssertEqual(api.requests.map(\.route), [.challenge])
    }

    func testHashesMatchTheServerContract() throws {
        let challenge = GuestDeviceChallenge(challengeId: challengeId, nonce: nonce, expiresAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(60)))
        let registration = try challenge.clientDataHash(for: .register, keyHash: fingerprint, at: now)
        let confirmation = try challenge.clientDataHash(for: .deviceCheck, keyHash: fingerprint, at: now)
        XCTAssertEqual(hex(registration), "9a2db2e23f1504cd056606553ac049c5e718e8f9ce9233876df1a7a1821af885")
        XCTAssertEqual(hex(confirmation), "98b21bd37bccfadbe791854c39f1ace027c4969029dcab3a80dab0c150a3b399")
    }

    @MainActor
    func testShortCodeIsOnlyAHeaderOnTheExactProofPreview() throws {
        let host = "phrabit-ios-guest-preview-012345678-renponpons-projects.vercel.app"
        let origin = try XCTUnwrap(URL(string: "https://" + host))
        let code = String(repeating: "ab", count: 32)
        let transport = try GuestCheckPreviewTransport(origin: origin, code: code)
        let body = Data(#"{"purpose":"device-check"}"#.utf8)
        let request = try transport.request(.challenge, body)
        XCTAssertEqual(request.url?.absoluteString, "https://" + host + "/api/ios/guest/challenge")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-phrabit-preview-pass"), code)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.httpBody, body)
        XCTAssertThrowsError(try transport.request(.register, Data(count: 36 * 1024)))
        transport.close()
        XCTAssertThrowsError(try transport.request(.challenge, body))

        let refused = [
            "http://" + host, "https://phrabit.com", "https://" + host + ":443",
            "https://" + host + "/api/ios/guest/status", "https://" + host + "?pass=test",
            "https://" + host + "#code", "https://example.com@" + host, "https://" + host + ".example.com"
        ]
        for address in refused {
            let candidate = try XCTUnwrap(URL(string: address))
            XCTAssertThrowsError(try GuestCheckPreviewTransport(origin: candidate, code: code))
        }
        XCTAssertThrowsError(try GuestCheckPreviewTransport(origin: origin, code: "wrong"))
    }

    private func challenge(offset: TimeInterval, isConfirmation: Bool = false) -> Data {
        let identifier = isConfirmation ? String(challengeId.dropLast()) + "3" : challengeId
        let challengeNonce = isConfirmation ? String(repeating: "ce", count: 32) : nonce
        let expiresAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(offset))
        return Data("""
        {"challengeId":"\(identifier)","nonce":"\(challengeNonce)","expiresAt":"\(expiresAt)"}
        """.utf8)
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

@MainActor
private final class TestProvider: GuestAttestProvider {
    let identifier = Data(repeating: 0xcd, count: 32).base64EncodedString()
    let isSupported = true
    var created = 0
    var attestedKeys: [String] = []
    var assertedKeys: [String] = []
    var attestedDigest: Data?
    var assertedDigest: Data?

    func generateKey() async throws -> String {
        created += 1
        return identifier
    }

    func attestKey(_ identifier: String, clientDataHash: Data) async throws -> Data {
        attestedKeys.append(identifier)
        attestedDigest = clientDataHash
        return Data([1])
    }

    func generateAssertion(_ identifier: String, clientDataHash: Data) async throws -> Data {
        assertedKeys.append(identifier)
        assertedDigest = clientDataHash
        return Data([2])
    }
}

@MainActor
private final class TestKeyStore: GuestAttestKeyStore {
    var key: GuestAttestKey?

    func read() throws -> GuestAttestKey? { key }

    func insert(_ key: GuestAttestKey) throws {
        guard self.key == nil else { throw GuestDeviceCheckError.storageUnavailable }
        self.key = key
    }

    func replace(_ old: GuestAttestKey, with new: GuestAttestKey) throws {
        guard self.key == old else { throw GuestDeviceCheckError.storageUnavailable }
        self.key = new
    }
}

@MainActor
private final class TestEndpoint {
    let first: Data
    let second: Data
    var requests: [(route: GuestCheckJSONAPI.Route, object: [String: String])] = []
    var dropRegistrationReply = false
    var storedFingerprint: String?

    init(first: Data, second: Data) {
        self.first = first
        self.second = second
    }

    func send(_ route: GuestCheckJSONAPI.Route, _ body: Data) async throws -> GuestCheckJSONAPI.Reply {
        let object = try JSONDecoder().decode([String: String].self, from: body)
        requests.append((route, object))
        switch route {
        case .challenge:
            return .init(status: 200, body: object["purpose"] == "register" ? first : second)
        case .register:
            storedFingerprint = object["keyHash"]
            if dropRegistrationReply { throw URLError(.networkConnectionLost) }
            return .init(status: 201, body: Data(#"{"status":"registered"}"#.utf8))
        case .confirm:
            let known = storedFingerprint != nil && object["keyHash"] == storedFingerprint
            return .init(status: known ? 200 : 401, body: Data(#"{"status":"verified"}"#.utf8))
        }
    }
}
