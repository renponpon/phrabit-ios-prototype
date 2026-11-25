import Foundation
import SwiftUI
import PhrabitCaptureCore

#if PHRABIT_OFFLINE_GUEST_TESTFLIGHT && (PHRABIT_LOCAL_LIVE_AUDIO || PHRABIT_PREVIEW_TRANSLATION_HOME || PHRABIT_OFFLINE_STARTUP_TIMING || PHRABIT_OFFLINE_TRANSLATION_HOME || PHRABIT_OFFLINE_GUEST_HOME)
#error("The guest TestFlight build cannot include other capture variants.")
#endif
#if PHRABIT_GUEST_DEVICE_MOCK && (!DEBUG || !PHRABIT_OFFLINE_GUEST_HOME || PHRABIT_OFFLINE_GUEST_TESTFLIGHT || PHRABIT_LOCAL_LIVE_AUDIO || PHRABIT_PREVIEW_TRANSLATION_HOME)
#error("The guest device mock requires the isolated, offline Debug build.")
#endif

@main
@MainActor
struct PhrabitCaptureApp: App {
    #if !(PHRABIT_OFFLINE_GUEST_TESTFLIGHT || (DEBUG && PHRABIT_OFFLINE_GUEST_HOME))
    @StateObject private var preview = CapturePreviewAuthLaunch()
    @Environment(\.scenePhase) private var scenePhase
    #endif

    var body: some Scene {
        WindowGroup {
            #if PHRABIT_OFFLINE_GUEST_TESTFLIGHT
            if Bundle.main.object(forInfoDictionaryKey: "PhrabitOfflineGuestTestFlight") as? Bool == true,
               Bundle.main.object(forInfoDictionaryKey: "PhrabitPreviewAuthOnly") == nil {
                GuestCaptureHomeView()
                    .preferredColorScheme(.dark)
            } else {
                ContentUnavailableView("試作版の設定を確認できません", systemImage: "exclamationmark.triangle")
            }
            #elseif DEBUG && PHRABIT_OFFLINE_GUEST_HOME
            GuestCaptureHomeView()
                .preferredColorScheme(.dark)
            #else
            switch preview.mode {
            case .offline(let model, let access):
                #if PHRABIT_OFFLINE_TRANSLATION_HOME
                captureLifecycle(TranslationHomeView(model: model, access: access), model: model)
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
                #if PHRABIT_PREVIEW_TRANSLATION_HOME
                captureLifecycle(TranslationHomeView(model: model, access: access, diagnostics: diagnostics), model: model)
                #else
                recordingView(model: model, access: access, diagnostics: diagnostics, audioPilot: true)
                #endif
            }
            #endif
        }
    }

    #if !(PHRABIT_OFFLINE_GUEST_TESTFLIGHT || (DEBUG && PHRABIT_OFFLINE_GUEST_HOME))
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
                    #if PHRABIT_OFFLINE_TRANSLATION_HOME || PHRABIT_PREVIEW_TRANSLATION_HOME
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
    #endif
}

