import SwiftUI
import PhrabitCaptureCore

@main
@MainActor
struct PhrabitCaptureApp: App {
    @StateObject private var preview = CapturePreviewAuthLaunch()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            switch preview.mode {
            case .offline(let model, let access):
                #if PHRABIT_OFFLINE_TRANSLATION_HOME
                captureLifecycle(TranslationHomeView(model: model), model: model)
                #else
                recordingView(model: model, access: access)
                #endif
            case .invalid:
                ContentUnavailableView("接続設定を確認できません", systemImage: "exclamationmark.triangle",
                                       description: Text("この検証版では録音や翻訳を行いません。"))
            case .preview(let previewAccess, let diagnostics, let usesCaptureEdge, let audioAccessOnly):
                CapturePreviewAuthView(access: previewAccess, diagnostics: diagnostics, usesCaptureEdge: usesCaptureEdge, audioAccessOnly: audioAccessOnly)
                    .preferredColorScheme(.dark)
            case .localRecording(let model, let access, let diagnostics):
                recordingView(model: model, access: access, diagnostics: diagnostics, localPreview: true)
            case .liveAudio(let model, let access, let diagnostics):
                recordingView(model: model, access: access, diagnostics: diagnostics, audioPilot: true)
            }
        }
    }

    private func recordingView(model: CaptureViewModel, access: CaptureAccessController, diagnostics: CaptureConnectionDiagnostics? = nil, localPreview: Bool = false, audioPilot: Bool = false) -> some View {
        captureLifecycle(CaptureView(model: model, access: access, diagnostics: diagnostics, localPreview: localPreview, audioPilot: audioPilot), model: model)
    }

    private func captureLifecycle<Content: View>(_ content: Content, model: CaptureViewModel) -> some View {
        content
            .preferredColorScheme(.dark)
            .task {
                if scenePhase == .active {
                    model.handlePendingLaunch()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: CaptureLaunchRequest.notification)) { _ in
                if scenePhase == .active {
                    model.handlePendingLaunch()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    #if PHRABIT_OFFLINE_TRANSLATION_HOME
                    model.refreshTranslationMicrophoneSetup()
                    #endif
                    model.handlePendingLaunch()
                case .background:
                    model.stopForBackground()
                default:
                    break
                }
            }
    }
}

