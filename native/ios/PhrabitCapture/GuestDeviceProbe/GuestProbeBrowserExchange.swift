import Combine
import Foundation

@MainActor
final class GuestProbeBrowserExchange: ObservableObject {
    struct Outgoing: Encodable {
        let id: String
        let path: String
        let body: String
    }

    private struct Incoming: Decodable {
        let id: String
        let status: Int
        let body: String
    }

    @Published private(set) var pending: Outgoing?
    private var waiting: CheckedContinuation<GuestCheckJSONAPI.Reply, Error>?

    func send(_ route: GuestCheckJSONAPI.Route, _ body: Data) async throws -> GuestCheckJSONAPI.Reply {
        guard waiting == nil, body.count <= 35 * 1024,
              let json = String(data: body, encoding: .utf8) else { throw GuestDeviceCheckError.unexpectedResponse }
        let item = Outgoing(id: UUID().uuidString.lowercased(), path: route.rawValue, body: json)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiting = continuation
                pending = item
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if self?.pending?.id == item.id { self?.cancel() }
            }
        }
    }

    func copyableRequest() -> String? {
        guard let pending, let data = try? JSONEncoder().encode(pending) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func accept(_ value: String) -> Bool {
        guard let pending, let waiting, value.utf8.count <= 4_096,
              let result = try? JSONDecoder().decode(Incoming.self, from: Data(value.utf8)),
              result.id == pending.id, (200...599).contains(result.status),
              (1...2_048).contains(result.body.utf8.count) else { return false }
        self.waiting = nil
        self.pending = nil
        waiting.resume(returning: .init(status: result.status, body: Data(result.body.utf8)))
        return true
    }

    func cancel() {
        let continuation = waiting
        waiting = nil
        pending = nil
        continuation?.resume(throwing: CancellationError())
    }
}
