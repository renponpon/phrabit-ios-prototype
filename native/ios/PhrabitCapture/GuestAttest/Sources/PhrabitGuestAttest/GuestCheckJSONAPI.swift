import Foundation

@MainActor
final class GuestCheckJSONAPI: GuestDeviceCheckAPI {
    enum Route: String {
        case challenge = "/api/ios/guest/challenge"
        case register = "/api/ios/guest/register"
        case confirm = "/api/ios/guest/device-check"
    }

    struct Reply {
        let status: Int
        let body: Data
    }

    private struct ChallengeRequest: Encodable {
        let purpose: GuestChallengePurpose
        let keyHash: String
    }

    private struct StatusReply: Decodable {
        let status: String
    }

    private let exchange: @MainActor (Route, Data) async throws -> Reply

    init(exchange: @escaping @MainActor (Route, Data) async throws -> Reply) {
        self.exchange = exchange
    }

    func challenge(_ purpose: GuestChallengePurpose, keyHash: String) async throws -> GuestDeviceChallenge {
        let body = try await send(.challenge, ChallengeRequest(purpose: purpose, keyHash: keyHash), expected: 200)
        return try JSONDecoder().decode(GuestDeviceChallenge.self, from: body)
    }

    func register(_ request: GuestDeviceProof) async throws {
        let body = try await send(.register, request, expected: 201)
        guard try JSONDecoder().decode(StatusReply.self, from: body).status == "registered" else {
            throw GuestDeviceCheckError.unexpectedResponse
        }
    }

    func confirm(_ request: GuestDeviceProof) async throws {
        let body = try await send(.confirm, request, expected: 200)
        guard try JSONDecoder().decode(StatusReply.self, from: body).status == "verified" else {
            throw GuestDeviceCheckError.unexpectedResponse
        }
    }

    private func send<Request: Encodable>(_ route: Route, _ request: Request, expected: Int) async throws -> Data {
        let reply = try await exchange(route, JSONEncoder().encode(request))
        guard reply.status == expected, !reply.body.isEmpty, reply.body.count <= 2_048 else {
            throw GuestDeviceCheckError.unexpectedResponse
        }
        return reply.body
    }
}
