import Combine
import Foundation

@MainActor
public final class CaptureConnectionDiagnostics: ObservableObject {
    public enum State: Equatable { case idle, checking, ready, failed(String) }
    @Published public private(set) var state: State = .idle
    public var isBusy: Bool { state == .checking }
    private let access: CaptureAccessController
    private let check: @MainActor () async throws -> Void
    private var operation: Task<Void, Never>?
    private var operationID: UUID?

    public init(access: CaptureAccessController, check: @escaping @MainActor () async throws -> Void) {
        self.access = access
        self.check = check
    }

    public func run() {
        guard !isBusy else { return }
        guard access.canRecord else { state = .failed(CaptureConnectionCheckError.signInRequired.localizedDescription); return }
        let identifier = UUID()
        let revision = access.sessionRevision
        operationID = identifier
        state = .checking
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if self.operationID == identifier { self.operationID = nil; self.operation = nil } }
            do {
                try await self.check()
                try Task.checkCancellation()
                guard self.operationID == identifier else { return }
                guard self.access.canRecord, self.access.sessionRevision == revision else { self.state = .idle; return }
                self.state = .ready
            } catch {
                guard self.operationID == identifier else { return }
                guard self.access.canRecord, self.access.sessionRevision == revision else { self.state = .idle; return }
                if error is CancellationError { self.state = .idle; return }
                let failure = (error as? CaptureConnectionCheckError) ?? .network
                if case .signInRequired = failure { self.access.clearSession() }
                self.state = .failed(failure.localizedDescription)
            }
        }
    }

    public func cancel() {
        operationID = nil
        operation?.cancel()
        operation = nil
        state = .idle
    }
}
