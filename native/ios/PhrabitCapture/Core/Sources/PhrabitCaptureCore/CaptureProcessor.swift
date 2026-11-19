import Foundation

@MainActor
public protocol CaptureProcessing {
    var sendsAudio: Bool { get }
    func transcribe(audio: Data, durationMilliseconds: Int, sessionID: UUID) async throws -> String
    func translate(text: String, to language: CaptureLanguage, sessionID: UUID) async throws -> CaptureTranslation
}

public struct MockCaptureProcessor: CaptureProcessing {
    public let sendsAudio = false

    public init() {}

    public func transcribe(audio: Data, durationMilliseconds: Int, sessionID: UUID) async throws -> String {
        try Task.checkCancellation()
        return MockTranslator.sample(for: .chinese).sourceText
    }

    public func translate(text: String, to language: CaptureLanguage, sessionID: UUID) async throws -> CaptureTranslation {
        try await MockTranslator().translate(to: language)
    }
}

public enum CaptureClientError: LocalizedError {
    case invalidConfiguration
    case authenticationRequired
    case deploymentProtected
    case invalidInput
    case invalidResponse
    case unavailable
    case limited
    case pilotAlreadyAttempted
    case budgetUnavailable
    case requestFailed

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "接続設定を確認してください。"
        case .authenticationRequired: return "Phrabitに再ログインしてください。"
        case .deploymentProtected: return "検証サーバーのアクセス設定を確認してください。再ログインでは解消しません。"
        case .invalidInput: return "入力内容を確認し、短く録音し直してください。"
        case .invalidResponse: return "応答を読み取れませんでした。送信済み処理の料金が発生する場合があります。"
        case .unavailable: return "この試作はまだ利用できません。"
        case .limited: return "利用上限に達しました。時間をおいてお試しください。"
        case .pilotAlreadyAttempted: return "この回の検証は試行済みです。再送せず、この画面を確認してください。"
        case .budgetUnavailable: return "利用上限を確認できないため停止しています。"
        case .requestFailed: return "通信を完了できませんでした。送信済み処理の料金が発生する場合があります。"
        }
    }
}
