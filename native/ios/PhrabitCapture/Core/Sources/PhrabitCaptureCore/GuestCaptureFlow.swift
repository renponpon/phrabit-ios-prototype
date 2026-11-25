import Foundation

public enum GuestCaptureEntry: Equatable, Sendable {
    case consent, microphone, microphoneSettings, record

    public init(consent: Bool, permission: CaptureTranslationHomeRules.MicrophonePermission) {
        guard consent else { self = .consent; return }
        switch permission {
        case .notRequested: self = .microphone
        case .denied: self = .microphoneSettings
        case .allowed: self = .record
        }
    }
}

public enum GuestCaptureFeedback: String, Error, CaseIterable, Hashable, Sendable {
    case daily, serviceBudget, offline, deviceCheck, burst, provider

    public var title: String {
        switch self {
        case .daily: return "今日の利用枠を使い切りました"
        case .serviceBudget: return "今は音声翻訳を利用できません"
        case .offline: return "音声を送信できませんでした"
        case .deviceCheck: return "この端末を確認できませんでした"
        case .burst: return "しばらくお待ちください"
        case .provider: return "訳を表示できませんでした"
        }
    }

    public var consumesAttempt: Bool { self == .provider }
}

public struct GuestQuotaSnapshot: Equatable, Sendable {
    public let remaining: Int
    public let nextReset: Date

    public init(remaining: Int, nextReset: Date) {
        self.remaining = max(0, remaining)
        self.nextReset = nextReset
    }
}

public struct GuestCaptureFixture: Sendable {
    public static let maximumRecordingDuration: TimeInterval = 15
    public private(set) var quota: GuestQuotaSnapshot
    public private(set) var simulatedIssue: GuestCaptureFeedback?
    private var submitted: Set<UUID> = []

    public init(response: GuestQuotaSnapshot, issue: GuestCaptureFeedback? = nil) {
        quota = response
        simulatedIssue = issue
    }

    public func checkAvailable(_ id: UUID) throws {
        guard !submitted.contains(id) else { throw CancellationError() }
        if quota.remaining == 0 { throw GuestCaptureFeedback.daily }
        if let simulatedIssue, !simulatedIssue.consumesAttempt { throw simulatedIssue }
    }

    public mutating func attempt(_ id: UUID) throws {
        try checkAvailable(id)
        submitted.insert(id)
        quota = GuestQuotaSnapshot(remaining: quota.remaining - 1, nextReset: quota.nextReset)
        if let simulatedIssue { throw simulatedIssue }
    }
}
