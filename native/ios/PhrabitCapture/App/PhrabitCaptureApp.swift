import SwiftUI
import PhrabitCaptureCore

@main
@MainActor
struct PhrabitCaptureApp: App {
    @StateObject private var model = CaptureViewModel()
    @StateObject private var access = CaptureAccessController.mock()
    @StateObject private var preview = CapturePreviewAuthLaunch()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            switch preview.mode {
            case .offline:
                offlineView
            case .invalid:
                ContentUnavailableView("接続設定を確認できません", systemImage: "exclamationmark.triangle",
                                       description: Text("この検証版では録音や翻訳を行いません。"))
            case .preview(let previewAccess, let diagnostics):
                CapturePreviewAuthView(access: previewAccess, diagnostics: diagnostics)
                    .preferredColorScheme(.dark)
            }
        }
    }

    private var offlineView: some View {
        CaptureView(model: model, access: access)
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
                    model.handlePendingLaunch()
                case .background:
                    model.stopForBackground()
                default:
                    break
                }
            }
    }
}

