import Foundation

public enum CaptureLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case chinese = "zh"

    public var displayName: String {
        switch self {
        case .english: return "英語"
        case .chinese: return "中国語"
        }
    }
}

public struct CaptureTranslation: Equatable, Sendable {
    public let sourceText: String
    public let targetText: String
    public let reading: String?
    public let language: CaptureLanguage

    public init(sourceText: String, targetText: String, reading: String?, language: CaptureLanguage) {
        self.sourceText = sourceText
        self.targetText = targetText
        self.reading = reading
        self.language = language
    }
}

public struct CaptureSession: Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case preparing
        case recording
        case recognizing
        case translating
        case result(CaptureTranslation)
        case failed(String)
    }

    public static let maximumRecordingDuration: TimeInterval = 20
    public private(set) var state: State = .idle
    public private(set) var operationID: UUID?
    public private(set) var language: CaptureLanguage = .chinese

    public init() {}

    public var isBusy: Bool {
        switch state {
        case .preparing, .recording, .recognizing, .translating: return true
        case .idle, .result, .failed: return false
        }
    }

    public mutating func begin(language: CaptureLanguage) -> UUID? {
        guard !isBusy else { return nil }
        let identifier = UUID()
        operationID = identifier
        self.language = language
        state = .preparing
        return identifier
    }

    public mutating func beginTypedTranslation(language: CaptureLanguage) -> UUID? {
        guard !isBusy else { return nil }
        let identifier = UUID()
        operationID = identifier
        self.language = language
        state = .translating
        return identifier
    }

    public mutating func recordingBegan(for identifier: UUID) {
        guard operationID == identifier, state == .preparing else { return }
        state = .recording
    }

    public mutating func beginTranslation() -> UUID? {
        guard state == .recording, let identifier = operationID else { return nil }
        state = .translating
        return identifier
    }

    public mutating func beginRecognition() -> UUID? {
        guard state == .recording, let identifier = operationID else { return nil }
        state = .recognizing
        return identifier
    }

    public mutating func recognitionCompleted(for identifier: UUID) -> Bool {
        guard state == .recognizing, operationID == identifier else { return false }
        state = .translating
        return true
    }

    public mutating func retryTranslation() -> UUID? {
        guard case .failed = state else { return nil }
        let identifier = UUID()
        operationID = identifier
        state = .translating
        return identifier
    }

    public mutating func complete(_ translation: CaptureTranslation, for identifier: UUID) {
        guard operationID == identifier, state == .translating, translation.language == language else { return }
        state = .result(translation)
        operationID = nil
    }

    public mutating func fail(_ message: String, for identifier: UUID) {
        guard operationID == identifier else { return }
        state = .failed(message)
        operationID = nil
    }

    public mutating func cancel() {
        operationID = nil
        state = .idle
    }
}

