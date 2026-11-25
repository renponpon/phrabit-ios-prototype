#if DEBUG
import Foundation
import XCTest
@testable import PhrabitGuestAttest

final class GuestMockDeviceCheckTests: XCTestCase {
    @MainActor
    func testFirstStopRegistersAndConfirmsAndNextStopReusesRegistration() async throws {
        let device = GuestMockDeviceCheck()
        XCTAssertEqual(device.completedRegistrations, 0)
        XCTAssertEqual(device.completedConfirmations, 0)
        try await device.verifyBeforeMockTranslation()
        XCTAssertEqual(device.completedRegistrations, 1)
        XCTAssertEqual(device.completedConfirmations, 1)
        try await device.verifyBeforeMockTranslation()
        XCTAssertEqual(device.completedRegistrations, 1)
        XCTAssertEqual(device.completedConfirmations, 2)
    }

    @MainActor
    func testWrongDigestAndReplayedProofAreRejected() async throws {
        let device = GuestMockDeviceState()
        let api = GuestCheckJSONAPI(exchange: device.exchange)
        let flow = GuestDeviceCheckFlow(provider: device, keyStore: device, api: api)
        let keyHash = try await flow.prepare()
        try await flow.enroll()
        let challenge = try await api.challenge(.deviceCheck, keyHash: keyHash)
        let identifier = try XCTUnwrap(device.savedKey?.identifier)
        let wrongSignature = try await device.generateAssertion(identifier, clientDataHash: Data(repeating: 0, count: 32))
        do {
            try await api.confirm(GuestDeviceProof(challengeId: challenge.challengeId, keyHash: keyHash,
                                                  proof: wrongSignature.base64EncodedString()))
            XCTFail("The proof must be bound to the challenge")
        } catch {
            XCTAssertEqual(error as? GuestDeviceCheckError, .invalidProof)
        }
        XCTAssertEqual(device.completedConfirmations, 0)
        let digest = try challenge.clientDataHash(for: .deviceCheck, keyHash: keyHash, at: Date())
        let signature = try await device.generateAssertion(identifier, clientDataHash: digest)
        let valid = GuestDeviceProof(challengeId: challenge.challengeId, keyHash: keyHash, proof: signature.base64EncodedString())
        try await api.confirm(valid)
        do {
            try await api.confirm(valid)
            XCTFail("A consumed challenge cannot be used again")
        } catch {
            XCTAssertEqual(error as? GuestDeviceCheckError, .invalidProof)
        }
        XCTAssertEqual(device.completedConfirmations, 1)
    }
}
#endif
