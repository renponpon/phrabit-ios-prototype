import CryptoKit
import Foundation

enum GuestDeviceCheckError: Error, Equatable {
    case busy, unsupported, invalidKey, invalidChallenge, invalidProof, unsupportedKeyState
    case confirmationRequired, storageUnavailable, unexpectedResponse
}

struct GuestAttestKey: Codable, Equatable {
    enum Phase: String, Codable {
        case allocated, awaitingConfirmation, registered
    }

    let identifier: String
    var phase: Phase
    let previousIdentifier: String?
    let earliestIdentifier: String?

    init(identifier: String, phase: Phase, previousIdentifier: String? = nil, earliestIdentifier: String? = nil) {
        self.identifier = identifier
        self.phase = phase
        self.previousIdentifier = previousIdentifier
        self.earliestIdentifier = earliestIdentifier
    }

    var canPrepareRetry: Bool { phase == .awaitingConfirmation && earliestIdentifier == nil }

    func permitsUpdate(to new: Self) -> Bool {
        if identifier == new.identifier {
            return previousIdentifier == new.previousIdentifier && earliestIdentifier == new.earliestIdentifier &&
                ((phase == .allocated && new.phase == .awaitingConfirmation) ||
                 (phase == .awaitingConfirmation && new.phase == .registered))
        }
        return canPrepareRetry && new.phase == .allocated && new.previousIdentifier == identifier &&
            new.earliestIdentifier == previousIdentifier && new.identifier != previousIdentifier
    }

    func fingerprint() throws -> String {
        guard let bytes = Data(base64Encoded: identifier), bytes.count == 32,
              bytes.base64EncodedString() == identifier else { throw GuestDeviceCheckError.invalidKey }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

enum GuestChallengePurpose: String, Encodable {
    case register
    case deviceCheck = "device-check"
}

struct GuestDeviceChallenge: Decodable {
    let challengeId: String
    let nonce: String
    let expiresAt: String

    func nonceData(at now: Date) throws -> Data {
        let timestamp = ISO8601DateFormatter()
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expires = timestamp.date(from: expiresAt) ?? ISO8601DateFormatter().date(from: expiresAt)
        guard challengeId.range(of: #"\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z"#,
                                options: .regularExpression) != nil,
              nonce.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil,
              let expires, expires > now, expires.timeIntervalSince(now) <= 120 else {
            throw GuestDeviceCheckError.invalidChallenge
        }
        let characters = Array(nonce.utf8)
        return Data(stride(from: 0, to: characters.count, by: 2).map { index in
            func nibble(_ character: UInt8) -> UInt8 { character < 58 ? character - 48 : character - 87 }
            return nibble(characters[index]) * 16 + nibble(characters[index + 1])
        })
    }

    func clientDataHash(for purpose: GuestChallengePurpose, keyHash: String, at now: Date) throws -> Data {
        let bytes = try nonceData(at: now)
        if purpose == .register { return Data(SHA256.hash(data: bytes)) }
        let payload = [
            "phrabit-ios-guest-device-check-v1", "POST", "/api/ios/guest/device-check", challengeId, nonce, keyHash
        ].joined(separator: "\n")
        return Data(SHA256.hash(data: Data(payload.utf8)))
    }
}

@MainActor
protocol GuestAttestProvider {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ identifier: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ identifier: String, clientDataHash: Data) async throws -> Data
}

@MainActor
protocol GuestAttestKeyStore {
    func read() throws -> GuestAttestKey?
    func insert(_ key: GuestAttestKey) throws
    func replace(_ old: GuestAttestKey, with new: GuestAttestKey) throws
}

struct GuestDeviceProof: Encodable {
    let challengeId: String
    let keyHash: String
    let proof: String
}

@MainActor
protocol GuestDeviceCheckAPI {
    func challenge(_ purpose: GuestChallengePurpose, keyHash: String) async throws -> GuestDeviceChallenge
    func register(_ request: GuestDeviceProof) async throws
    func confirm(_ request: GuestDeviceProof) async throws
}

@MainActor
final class GuestDeviceCheckFlow {
    private let provider: GuestAttestProvider
    private let keyStore: GuestAttestKeyStore
    private let api: GuestDeviceCheckAPI
    private let now: () -> Date
    private var busy = false

    init(provider: GuestAttestProvider, keyStore: GuestAttestKeyStore, api: GuestDeviceCheckAPI, now: @escaping () -> Date = Date.init) {
        self.provider = provider
        self.keyStore = keyStore
        self.api = api
        self.now = now
    }

    func prepare() async throws -> String {
        try begin()
        defer { busy = false }
        if let saved = try keyStore.read() { return try saved.fingerprint() }
        let allocated = GuestAttestKey(identifier: try await provider.generateKey(), phase: .allocated)
        let keyHash = try allocated.fingerprint()
        try keyStore.insert(allocated)
        return keyHash
    }

    func prepareRegistrationRetry() async throws -> String {
        try begin()
        defer { busy = false }
        guard let saved = try keyStore.read(), saved.canPrepareRetry else {
            throw GuestDeviceCheckError.unsupportedKeyState
        }
        _ = try saved.fingerprint()
        let replacement = GuestAttestKey(identifier: try await provider.generateKey(), phase: .allocated,
                                         previousIdentifier: saved.identifier, earliestIdentifier: saved.previousIdentifier)
        let keyHash = try replacement.fingerprint()
        guard saved.identifier != replacement.identifier, saved.permitsUpdate(to: replacement) else {
            throw GuestDeviceCheckError.invalidKey
        }
        try Task.checkCancellation()
        try keyStore.replace(saved, with: replacement)
        return keyHash
    }

    func enroll() async throws {
        try begin()
        defer { busy = false }
        guard let allocated = try keyStore.read() else { throw GuestDeviceCheckError.unsupportedKeyState }
        guard allocated.phase == .allocated else { throw GuestDeviceCheckError.confirmationRequired }
        let keyHash = try allocated.fingerprint()
        let challenge = try await api.challenge(.register, keyHash: keyHash)
        let clientDataHash = try challenge.clientDataHash(for: .register, keyHash: keyHash, at: now())
        try Task.checkCancellation()
        var pending = allocated
        pending.phase = .awaitingConfirmation
        try keyStore.replace(allocated, with: pending)
        let proof = try await provider.attestKey(allocated.identifier, clientDataHash: clientDataHash)
        guard !proof.isEmpty, proof.count <= 24 * 1024 else { throw GuestDeviceCheckError.invalidProof }
        _ = try challenge.nonceData(at: now())
        try Task.checkCancellation()
        try await api.register(GuestDeviceProof(challengeId: challenge.challengeId, keyHash: keyHash, proof: proof.base64EncodedString()))
        var registered = pending
        registered.phase = .registered
        try keyStore.replace(pending, with: registered)
    }

    func confirm() async throws {
        try begin()
        defer { busy = false }
        guard let saved = try keyStore.read(), saved.phase != .allocated else { throw GuestDeviceCheckError.unsupportedKeyState }
        let keyHash = try saved.fingerprint()
        let challenge = try await api.challenge(.deviceCheck, keyHash: keyHash)
        let clientDataHash = try challenge.clientDataHash(for: .deviceCheck, keyHash: keyHash, at: now())
        try Task.checkCancellation()
        let proof = try await provider.generateAssertion(saved.identifier, clientDataHash: clientDataHash)
        guard !proof.isEmpty, proof.count <= 1024 else { throw GuestDeviceCheckError.invalidProof }
        _ = try challenge.nonceData(at: now())
        try Task.checkCancellation()
        try await api.confirm(GuestDeviceProof(challengeId: challenge.challengeId, keyHash: keyHash, proof: proof.base64EncodedString()))
        if saved.phase == .awaitingConfirmation {
            var registered = saved
            registered.phase = .registered
            try keyStore.replace(saved, with: registered)
        }
    }

    private func begin() throws {
        guard !busy else { throw GuestDeviceCheckError.busy }
        guard provider.isSupported else { throw GuestDeviceCheckError.unsupported }
        try Task.checkCancellation()
        busy = true
    }
}
