import AuthenticationServices
import PhrabitCaptureCore
import UIKit

@MainActor
final class CaptureBrowserLogin: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var operationID: UUID?

    func open(_ url: URL) async throws -> URL {
        guard session == nil else { throw CaptureAccessError.authentication }
        try Task.checkCancellation()
        let identifier = UUID()
        operationID = identifier
        defer { if operationID == identifier { operationID = nil; session = nil; continuation = nil } }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard self.operationID == identifier, !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: CaptureAuthConfiguration.callbackURL.scheme) { [weak self] result, error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let result { self.finish(.success(result), for: identifier) }
                        else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { self.finish(.failure(CancellationError()), for: identifier) }
                        else { self.finish(.failure(CaptureAccessError.authentication), for: identifier) }
                    }
                }
                self.session = session
                session.presentationContextProvider = self
                if !session.start() { finish(.failure(CaptureAccessError.authentication), for: identifier) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(for: identifier) }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }.first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    private func cancel(for identifier: UUID) {
        guard operationID == identifier else { return }
        session?.cancel()
        finish(.failure(CancellationError()), for: identifier)
    }

    private func finish(_ result: Result<URL, Error>, for identifier: UUID) {
        guard operationID == identifier else { return }
        let pending = continuation
        continuation = nil
        session = nil
        operationID = nil
        pending?.resume(with: result)
    }
}
