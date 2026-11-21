import Foundation
import PhrabitCaptureCore
import SwiftUI

@MainActor
final class CapturePreviewAuthLaunch: ObservableObject {
    enum Mode {
        case offline(CaptureViewModel, CaptureAccessController)
        case invalid
        case preview(CaptureAccessController, CaptureConnectionDiagnostics, usesCaptureEdge: Bool, audioAccessOnly: Bool)
        case localRecording(CaptureViewModel, CaptureAccessController, CaptureConnectionDiagnostics)
        case liveAudio(CaptureViewModel, CaptureAccessController, CaptureConnectionDiagnostics)
    }

    let mode: Mode

    init(bundle: Bundle = .main) {
        let diagnosticsOnly = bundle.object(forInfoDictionaryKey: "PhrabitDiagnosticsOnly") as? Bool == true
        #if PHRABIT_PREVIEW_TRANSLATION_HOME
        guard !diagnosticsOnly,
              let pilotSettings = bundle.object(forInfoDictionaryKey: "PhrabitPreviewAuthOnly") as? [String: String],
              Self.supportsLiveAudio(pilotSettings) else {
            mode = .invalid
            return
        }
        #endif
        #if PHRABIT_OFFLINE_STARTUP_TIMING && PHRABIT_OFFLINE_TRANSLATION_HOME
        mode = .invalid
        #elseif PHRABIT_OFFLINE_STARTUP_TIMING || PHRABIT_OFFLINE_TRANSLATION_HOME
        if diagnosticsOnly || bundle.object(forInfoDictionaryKey: "PhrabitPreviewAuthOnly") != nil {
            mode = .invalid
        } else {
            mode = .offline(CaptureViewModel(processor: MockCaptureProcessor()), .mock())
        }
        #else
        guard let values = bundle.object(forInfoDictionaryKey: "PhrabitPreviewAuthOnly") else {
            if diagnosticsOnly {
                mode = .invalid
            } else {
                mode = .offline(CaptureViewModel(), .mock())
            }
            return
        }
        guard let settings = values as? [String: String],
              let reference = settings["ProjectRef"], reference.range(of: #"^[a-z]{20}$"#, options: .regularExpression) != nil,
              let key = settings["PublishableKey"], key.hasPrefix("sb_publishable_") else {
            mode = .invalid
            return
        }
        let usesCaptureEdge = settings["ConnectionCheck"] == "capture-edge-v1"
        let audioAccessOnly = settings["ConnectionCheck"] == "capture-audio-diagnostics-v1"
        guard diagnosticsOnly == audioAccessOnly else { mode = .invalid; return }
        let liveAudio = Self.supportsLiveAudio(settings)
        let localRecordingOnly = usesCaptureEdge && settings["LocalMockRecording"] == "true"
        var expectedKeys: Set<String> = ["ProjectRef", "PublishableKey"]
        if usesCaptureEdge || liveAudio || audioAccessOnly { expectedKeys.insert("ConnectionCheck") }
        if localRecordingOnly { expectedKeys.insert("LocalMockRecording") }
        guard Set(settings.keys) == expectedKeys else {
            mode = .invalid
            return
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "\(reference).supabase.co"
        guard let project = components.url,
              let configuration = try? CaptureAuthConfiguration(apiOrigin: project, projectURL: project, publishableKey: key) else {
            mode = .invalid
            return
        }
        #if PHRABIT_PREVIEW_TRANSLATION_HOME
        let storageNamespace = "preview-translation-home-v1"
        #else
        let storageNamespace = liveAudio ? "preview-audio-pilot-v1" : "preview-auth-only-v1"
        #endif
        let storage = CaptureEnvironmentStorage(base: CaptureCredentialStore(), namespace: storageNamespace)
        let browser = CaptureBrowserLogin()
        let backend = CaptureSupabaseAuthentication(configuration: configuration, storage: storage, openBrowser: { try await browser.open($0) })
        let access = CaptureAccessController(backend: backend, storage: storage, environmentID: configuration.environmentID,
                                             allowsVerifiedLocalRecording: localRecordingOnly || liveAudio, requiresPilotDeadline: liveAudio)
        let target: CaptureConnectionVerifier.PreviewTarget = liveAudio ? .captureAudioPilot : audioAccessOnly ? .captureAudio : usesCaptureEdge ? .captureEdge : .account
        guard let verifier = try? CaptureConnectionVerifier(previewAuth: configuration, target: target, access: access) else {
            mode = .invalid
            return
        }
        let diagnostics = CaptureConnectionDiagnostics(access: access, check: {
            let revision = access.sessionRevision
            if liveAudio {
                let deadline = try await verifier.verifyAudioPilot()
                try access.confirmLocalRecording(afterCheckFor: revision, until: deadline)
            } else {
                try await verifier.verify()
                if localRecordingOnly { try access.confirmLocalRecording(afterCheckFor: revision) }
            }
        })
        if localRecordingOnly {
            let model = CaptureViewModel(processor: MockCaptureProcessor(), recordingAllowed: { access.canRecordLocally })
            mode = .localRecording(model, access, diagnostics)
        } else if liveAudio {
            guard let processor = try? CaptureHTTPProcessor(previewAudio: configuration, consentGranted: { access.canRecordLocally },
                                                            accessToken: { try await access.validAccessToken() }) else {
                mode = .invalid
                return
            }
            let model = CaptureViewModel(processor: processor, recordingAllowed: { access.canRecordLocally },
                                         authenticationRequired: { access.clearSession() })
            mode = .liveAudio(model, access, diagnostics)
        } else {
            mode = .preview(access, diagnostics, usesCaptureEdge: usesCaptureEdge, audioAccessOnly: audioAccessOnly)
        }
        #endif
    }

    private static func supportsLiveAudio(_ settings: [String: String]) -> Bool {
        #if PHRABIT_LOCAL_LIVE_AUDIO
        return settings["ConnectionCheck"] == "capture-audio-pilot-v1"
        #else
        return false
        #endif
    }
}

struct CapturePreviewAuthView: View {
    @ObservedObject var access: CaptureAccessController
    let diagnostics: CaptureConnectionDiagnostics
    let usesCaptureEdge: Bool
    var audioAccessOnly = false
    var localRecordingOnly = false
    @State private var acknowledged = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("この版で確認すること") {
                    Text(localRecordingOnly ? "本人確認後、端末内で録音できます。音声は送信せず破棄し、話した内容ではなく固定の訳文を表示します。" : "検証環境でGoogleログインと接続だけを確認します。録音・翻訳・フレーズ保存はできません。")
                    if audioAccessOnly {
                        Text("接続確認は、案内された短い検証時間内に行ってください。")
                            .font(.footnote)
                    }
                    Text("ログイン時はGoogleと検証用Supabaseでアカウント情報を使用します。認証情報はこの端末のKeychainに保存します。")
                        .font(.footnote)
                }
                Section("Phrabitのアカウント") {
                    if !access.consentAccepted {
                        Toggle("確認しました", isOn: $acknowledged)
                        Button("同意して続ける", action: access.acceptConsent).disabled(!acknowledged)
                    } else {
                        switch access.state {
                        case .signingIn:
                            ProgressView("Googleでログイン中")
                            Button("ログインを中止", action: access.cancelSignIn)
                        case .signedIn:
                            Label("ログイン済み", systemImage: "person.crop.circle.badge.checkmark")
                            Button("この端末からログアウト", action: access.clearSession)
                        default:
                            Button("Googleでログイン", action: access.signIn)
                        }
                        Button("同意を取り消す", role: .destructive, action: access.withdrawConsent).disabled(access.isBusy)
                    }
                    if case .failed(let message) = access.state { Text(message).foregroundStyle(.red) }
                }
                CaptureConnectionDiagnosticsView(diagnostics: diagnostics, canCheck: access.canRecord, previewOnly: true,
                                                 previewCaptureEdge: usesCaptureEdge, previewAudioAccessOnly: audioAccessOnly)
                if localRecordingOnly {
                    Section {
                        if access.canRecordLocally {
                            Label("録音の準備ができました", systemImage: "checkmark.circle")
                        } else {
                            Text("Googleでログインし、接続を確認してからこの画面を閉じてください。次回から録音開始前にこの通信は行いません。")
                        }
                    }
                }
            }
            .navigationTitle("Phrabit 接続確認")
            .toolbar {
                if localRecordingOnly {
                    ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
                }
            }
            .onChange(of: access.sessionRevision) { _, _ in diagnostics.cancel() }
            .onDisappear { access.cancelSignIn(); diagnostics.cancel() }
        }
    }
}
