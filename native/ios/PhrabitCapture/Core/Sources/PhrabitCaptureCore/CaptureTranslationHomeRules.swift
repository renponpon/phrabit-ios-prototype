import Foundation

public enum CaptureTranslationHomeRules {
    public static let inputLimit = 500

    public enum MicrophonePermission: Equatable {
        case allowed
        case notRequested
        case denied
    }

    public enum MicrophoneEntry: Equatable {
        case setupRequired
        case startRecording
        case explainPermission
        case settingsRequired
    }

    public static func microphoneEntry(for permission: MicrophonePermission, recordingAllowed: Bool = true) -> MicrophoneEntry {
        guard recordingAllowed else { return .setupRequired }
        switch permission {
        case .allowed: return .startRecording
        case .notRequested: return .explainPermission
        case .denied: return .settingsRequired
        }
    }

    public static func validatedText(_ text: String) -> String? {
        guard text.utf16.count <= inputLimit else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
