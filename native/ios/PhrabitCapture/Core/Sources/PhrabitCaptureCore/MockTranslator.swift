import Foundation

public struct MockTranslator: Sendable {
    public init() {}

    public func translate(to language: CaptureLanguage) async throws -> CaptureTranslation {
        try Task.checkCancellation()
        try await Task.sleep(nanoseconds: 700_000_000)
        try Task.checkCancellation()
        return Self.sample(for: language)
    }

    public static func sample(for language: CaptureLanguage) -> CaptureTranslation {
        let sourceText = "部屋の掃除をお願いできますか？"
        switch language {
        case .english:
            return CaptureTranslation(
                sourceText: sourceText,
                targetText: "Could you clean my room, please?",
                reading: nil,
                language: language
            )
        case .chinese:
            return CaptureTranslation(
                sourceText: sourceText,
                targetText: "可以帮我打扫一下房间吗？",
                reading: "Kěyǐ bāng wǒ dǎsǎo yíxià fángjiān ma?",
                language: language
            )
        }
    }
}

