import SwiftUI
import PhrabitCaptureCore

@main
struct PhrabitCaptureApp: App {
    @StateObject private var model = CaptureViewModel()
    @StateObject private var access = CaptureAccessController.mock()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
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
}

