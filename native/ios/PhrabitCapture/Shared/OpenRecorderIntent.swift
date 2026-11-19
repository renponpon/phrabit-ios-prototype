import AppIntents
import Foundation

enum CaptureDestination: String, AppEnum {
    case recorder

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Phrabitの画面"
    static var caseDisplayRepresentations: [CaptureDestination: DisplayRepresentation] = [
        .recorder: "音声翻訳"
    ]
}

struct OpenRecorderIntent: OpenIntent {
    static var title: LocalizedStringResource = "話して翻訳"
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "画面")
    var target: CaptureDestination

    init() {
        target = .recorder
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if Bundle.main.object(forInfoDictionaryKey: "PhrabitDiagnosticsOnly") as? Bool != true {
            CaptureLaunchRequest.enqueue()
        }
        return .result()
    }
}

