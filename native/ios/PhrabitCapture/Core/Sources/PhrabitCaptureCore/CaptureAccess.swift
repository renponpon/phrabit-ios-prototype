import Combine
import Foundation

public protocol CaptureSecureStorage: Sendable {
    func store(key: String, value: Data) throws
    func retrieve(key: String) throws -> Data?
    func remove(key: String) throws
}

@MainActor
public protocol CaptureAuthenticating: AnyObject {
    var isMock: Bool { get }
    var cachedUserID: UUID? { get }
    func signIn() async throws -> UUID
    func accessToken() async throws -> String
    func clearLocalSession() throws
}

public enum CaptureAccessError: LocalizedError {
    case configuration, consent, authentication, storage, cancelled, callback, connection

    public var errorDescription: String? {
        switch self {
        case .configuration: return "接続設定を確認してください。"
        case .consent: return "音声と認識文の送信先を確認してください。"
        case .authentication: return "Phrabitにログインしてください。"
        case .storage: return "ログイン設定を安全に保存・削除できませんでした。もう一度お試しください。"
        case .cancelled: return "ログインを中止しました。"
        case .callback: return "ログインの戻り先を確認できませんでした。最初からやり直してください。"
        case .connection: return "ログインの更新に接続できませんでした。通信が戻ってからお試しください。"
        }
    }
}

@MainActor
public final class CaptureAccessController: ObservableObject {
    public enum State: Equatable { case consentRequired, signedOut, signingIn, signedIn, failed(String) }
    @Published public private(set) var state: State = .consentRequired
    @Published public private(set) var consentAccepted = false
    @Published public private(set) var userID: UUID?
    public var isMock: Bool { backend.isMock }
    public var isBusy: Bool { state == .signingIn }
    public var canRecord: Bool { consentAccepted && state == .signedIn && userID != nil }
    public var canRecordLocally: Bool { allowsVerifiedLocalRecording && canRecord && userID == localRecordingOwner }
    public var sessionRevision: UUID { generation }
    @Published private var localRecordingOwner: UUID?
    private let backend: any CaptureAuthenticating
    private let storage: any CaptureSecureStorage
    private let environmentID: String
    private let allowsVerifiedLocalRecording: Bool
    private var operationID: UUID?
    private var operation: Task<Void, Never>?
    private var refresh: Task<String, Error>?
    private var refreshID: UUID?
    private var generation = UUID()
    private let consentKey = "capture-consent-v1"

    public init(backend: any CaptureAuthenticating, storage: any CaptureSecureStorage, environmentID: String, allowsVerifiedLocalRecording: Bool = false) {
        self.backend = backend
        self.storage = CaptureEnvironmentStorage(base: storage, namespace: environmentID)
        self.environmentID = environmentID
        self.allowsVerifiedLocalRecording = allowsVerifiedLocalRecording
        do {
            if let bytes = try self.storage.retrieve(key: consentKey), let record = try? JSONDecoder().decode(ConsentRecord.self, from: bytes) {
                consentAccepted = record.version == 1 && record.environment == environmentID && record.accepted
                if consentAccepted, allowsVerifiedLocalRecording, let cached = backend.cachedUserID, cached == record.localRecordingOwner {
                    localRecordingOwner = cached
                }
            }
            userID = consentAccepted ? backend.cachedUserID : nil
            state = consentAccepted ? userID == nil ? .signedOut : .signedIn : .consentRequired
        } catch { state = .failed(CaptureAccessError.storage.localizedDescription) }
    }

    public func acceptConsent() {
        guard !isBusy else { return }
        do {
            try storeConsent(accepted: true)
            localRecordingOwner = nil
            consentAccepted = true
            userID = backend.cachedUserID
            state = userID == nil ? .signedOut : .signedIn
        } catch { consentAccepted = false; state = .failed(CaptureAccessError.storage.localizedDescription) }
    }

    public func signIn() {
        guard consentAccepted, !isBusy, state != .signedIn else { return }
        if allowsVerifiedLocalRecording {
            localRecordingOwner = nil
            do { try storeConsent(accepted: true) }
            catch { state = .failed(CaptureAccessError.storage.localizedDescription); return }
        }
        let identifier = UUID()
        operationID = identifier
        state = .signingIn
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let user = try await self.backend.signIn()
                try Task.checkCancellation()
                guard self.operationID == identifier, self.consentAccepted else { return }
                self.userID = user
                self.state = .signedIn
            } catch {
                guard self.operationID == identifier else { return }
                self.userID = nil
                self.state = error is CancellationError ? .signedOut : .failed((error as? CaptureAccessError)?.localizedDescription ?? "ログインを完了できませんでした。もう一度お試しください。")
            }
            if self.operationID == identifier { self.operationID = nil; self.operation = nil }
        }
    }

    public func cancelSignIn() {
        guard isBusy else { return }
        clearSession()
    }

    public func clearSession() {
        generation = UUID()
        operationID = nil
        operation?.cancel()
        operation = nil
        refresh?.cancel()
        refresh = nil
        refreshID = nil
        userID = nil
        localRecordingOwner = nil
        do {
            try backend.clearLocalSession()
            if allowsVerifiedLocalRecording { try storeConsent(accepted: consentAccepted) }
            state = consentAccepted ? .signedOut : .consentRequired
        }
        catch { state = .failed(CaptureAccessError.storage.localizedDescription) }
    }

    public func withdrawConsent() {
        consentAccepted = false
        clearSession()
        do {
            try storeConsent(accepted: false)
            state = .consentRequired
        } catch { state = .failed(CaptureAccessError.storage.localizedDescription) }
    }

    public func confirmLocalRecording(afterCheckFor revision: UUID) throws {
        try Task.checkCancellation()
        guard allowsVerifiedLocalRecording, canRecord, generation == revision, let owner = userID else { throw CancellationError() }
        do { try storeConsent(accepted: true, localRecordingOwner: owner) }
        catch { throw CaptureAccessError.storage }
        localRecordingOwner = owner
    }

    private func storeConsent(accepted: Bool, localRecordingOwner: UUID? = nil) throws {
        let record = ConsentRecord(version: 1, environment: environmentID, accepted: accepted, localRecordingOwner: localRecordingOwner)
        try storage.store(key: consentKey, value: JSONEncoder().encode(record))
    }

    public func validAccessToken() async throws -> String {
        guard canRecord else { throw CaptureAccessError.authentication }
        let expectedUser = userID
        let expectedGeneration = generation
        let identifier = refreshID ?? UUID()
        let task = refresh ?? Task { try await backend.accessToken() }
        refresh = task
        refreshID = identifier
        defer { if refreshID == identifier { refresh = nil; refreshID = nil } }
        do {
            let token = try await task.value
            try Task.checkCancellation()
            guard generation == expectedGeneration, consentAccepted, userID == expectedUser, backend.cachedUserID == expectedUser else { throw CaptureAccessError.authentication }
            return token
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let accessError = error as? CaptureAccessError, case .connection = accessError { throw accessError }
            if generation == expectedGeneration { clearSession() }
            throw CaptureAccessError.authentication
        }
    }

    public static func mock() -> CaptureAccessController {
        CaptureAccessController(backend: MockCaptureAuthentication(), storage: CaptureMemoryStorage(), environmentID: "offline-mock")
    }
}

public struct CaptureEnvironmentStorage: CaptureSecureStorage {
    private let base: any CaptureSecureStorage
    private let prefix: String
    public init(base: any CaptureSecureStorage, namespace: String) {
        self.base = base
        self.prefix = Data(namespace.utf8).base64EncodedString() + ":"
    }
    public func store(key: String, value: Data) throws { try base.store(key: prefix + key, value: value) }
    public func retrieve(key: String) throws -> Data? { try base.retrieve(key: prefix + key) }
    public func remove(key: String) throws { try base.remove(key: prefix + key) }
}

private struct ConsentRecord: Codable {
    let version: Int
    let environment: String
    let accepted: Bool
    let localRecordingOwner: UUID?
}

public final class CaptureMemoryStorage: CaptureSecureStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    public init() {}
    public func store(key: String, value: Data) throws { lock.lock(); defer { lock.unlock() }; values[key] = value }
    public func retrieve(key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    public func remove(key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = nil }
}

@MainActor
public final class MockCaptureAuthentication: CaptureAuthenticating {
    public let isMock = true
    public private(set) var cachedUserID: UUID?
    private var generation = UUID()
    public init() {}
    public func signIn() async throws -> UUID {
        let expected = generation
        try await Task.sleep(for: .milliseconds(300))
        guard expected == generation else { throw CancellationError() }
        let identifier = UUID()
        cachedUserID = identifier
        return identifier
    }
    public func accessToken() async throws -> String {
        guard cachedUserID != nil else { throw CaptureAccessError.authentication }
        return "mock-session-not-for-network-use"
    }
    public func clearLocalSession() throws { generation = UUID(); cachedUserID = nil }
}
