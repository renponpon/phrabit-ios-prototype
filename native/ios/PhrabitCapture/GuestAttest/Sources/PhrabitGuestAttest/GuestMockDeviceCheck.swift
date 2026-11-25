#if DEBUG
import CryptoKit
import Foundation

@MainActor
public final class GuestMockDeviceCheck {
    private let device: GuestMockDeviceState
    private let flow: GuestDeviceCheckFlow
    private var checking = false

    public init() {
        let device = GuestMockDeviceState()
        self.device = device
        flow = GuestDeviceCheckFlow(provider: device, keyStore: device, api: GuestCheckJSONAPI(exchange: device.exchange))
    }

    var completedRegistrations: Int { device.completedRegistrations }
    var completedConfirmations: Int { device.completedConfirmations }

    public func verifyBeforeMockTranslation() async throws {
        try Task.checkCancellation()
        guard !checking else { throw GuestDeviceCheckError.busy }
        checking = true
        defer { checking = false }
        do {
            _ = try await flow.prepare()
            if device.savedKey?.phase == .allocated {
                try await flow.enroll()
            }
            try await flow.confirm()
        } catch {
            device.discardPending()
            throw error
        }
    }
}

@MainActor
final class GuestMockDeviceState: GuestAttestProvider, GuestAttestKeyStore {
    private struct Message: Decodable {
        let keyHash: String
        let purpose: String?
        let challengeId: String?
        let proof: String?
    }

    let isSupported = true
    private(set) var savedKey: GuestAttestKey?
    private(set) var completedRegistrations = 0
    private(set) var completedConfirmations = 0
    private var pending: (purpose: GuestChallengePurpose, challenge: GuestDeviceChallenge)?
    private lazy var signingKey = P256.Signing.PrivateKey()

    func generateKey() async throws -> String {
        try Task.checkCancellation()
        return Data(SHA256.hash(data: signingKey.publicKey.x963Representation)).base64EncodedString()
    }

    func attestKey(_ identifier: String, clientDataHash: Data) async throws -> Data {
        try await generateAssertion(identifier, clientDataHash: clientDataHash)
    }

    func generateAssertion(_ identifier: String, clientDataHash: Data) async throws -> Data {
        try Task.checkCancellation()
        guard savedKey?.identifier == identifier else { throw GuestDeviceCheckError.invalidKey }
        return try signingKey.signature(for: clientDataHash).derRepresentation
    }

    func read() throws -> GuestAttestKey? { savedKey }

    func insert(_ key: GuestAttestKey) throws {
        guard savedKey == nil else { throw GuestDeviceCheckError.storageUnavailable }
        savedKey = key
    }

    func replace(_ old: GuestAttestKey, with new: GuestAttestKey) throws {
        guard savedKey == old, old.permitsUpdate(to: new) else { throw GuestDeviceCheckError.storageUnavailable }
        savedKey = new
    }

    func discardPending() {
        pending = nil
        if completedRegistrations == 0 { savedKey = nil }
    }

    func exchange(_ route: GuestCheckJSONAPI.Route, _ body: Data) async throws -> GuestCheckJSONAPI.Reply {
        try Task.checkCancellation()
        let message = try JSONDecoder().decode(Message.self, from: body)
        guard let savedKey, try savedKey.fingerprint() == message.keyHash else { throw GuestDeviceCheckError.invalidKey }
        switch route {
        case .challenge:
            let purpose: GuestChallengePurpose
            switch message.purpose ?? "" {
            case "register" where completedRegistrations == 0: purpose = .register
            case "device-check" where completedRegistrations == 1: purpose = .deviceCheck
            default: throw GuestDeviceCheckError.invalidChallenge
            }
            let challenge = GuestDeviceChallenge(
                challengeId: UUID().uuidString.lowercased(),
                nonce: SHA256.hash(data: Data(UUID().uuidString.utf8)).map { String(format: "%02x", $0) }.joined(),
                expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))
            )
            pending = (purpose, challenge)
            return try reply(200, ["challengeId": challenge.challengeId, "nonce": challenge.nonce, "expiresAt": challenge.expiresAt])
        case .register, .confirm:
            let purpose: GuestChallengePurpose = route == .register ? .register : .deviceCheck
            guard let pending, pending.purpose == purpose,
                  pending.challenge.challengeId == message.challengeId,
                  let proof = message.proof, let bytes = Data(base64Encoded: proof),
                  let signature = try? P256.Signing.ECDSASignature(derRepresentation: bytes) else {
                throw GuestDeviceCheckError.invalidProof
            }
            let digest = try pending.challenge.clientDataHash(for: purpose, keyHash: message.keyHash, at: Date())
            guard signingKey.publicKey.isValidSignature(signature, for: digest) else {
                throw GuestDeviceCheckError.invalidProof
            }
            self.pending = nil
            if purpose == .register {
                completedRegistrations += 1
                return try reply(201, ["status": "registered"])
            }
            completedConfirmations += 1
            return try reply(200, ["status": "verified"])
        }
    }

    private func reply(_ status: Int, _ body: [String: String]) throws -> GuestCheckJSONAPI.Reply {
        GuestCheckJSONAPI.Reply(status: status, body: try JSONEncoder().encode(body))
    }
}
#endif
