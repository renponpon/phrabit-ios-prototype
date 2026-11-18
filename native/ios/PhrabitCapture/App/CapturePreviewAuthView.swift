import Foundation
import PhrabitCaptureCore
import SwiftUI

@MainActor
final class CapturePreviewAuthLaunch: ObservableObject {
    enum Mode {
        case offline(CaptureViewModel, CaptureAccessController)
        case invalid
        case preview(CaptureAccessController, CaptureConnectionDiagnostics, usesCaptureEdge: Bool)
        case localRecording(CaptureViewModel, CaptureAccessController, CaptureConnectionDiagnostics)
    }

    let mode: Mode

    init(bundle: Bundle = .main) {
        guard let values = bundle.object(forInfoDictionaryKey: "PhrabitPreviewAuthOnly") else {
            mode = .offline(CaptureViewModel(), .mock())
            return
        }
        guard let settings = values as? [String: String],
              let reference = settings["ProjectRef"], reference.range(of: #"^[a-z]{20}$"#, options: .regularExpression) != nil,
              let key = settings["PublishableKey"], key.hasPrefix("sb_publishable_") else {
            mode = .invalid
            return
        }
        let usesCaptureEdge = settings["ConnectionCheck"] == "capture-edge-v1"
        let localRecordingOnly = usesCaptureEdge && settings["LocalMockRecording"] == "true"
        var expectedKeys: Set<String> = ["ProjectRef", "PublishableKey"]
        if usesCaptureEdge { expectedKeys.insert("ConnectionCheck") }
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
        let storage = CaptureEnvironmentStorage(base: CaptureCredentialStore(), namespace: "preview-auth-only-v1")
        let browser = CaptureBrowserLogin()
        let backend = CaptureSupabaseAuthentication(configuration: configuration, storage: storage, openBrowser: { try await browser.open($0) })
        let access = CaptureAccessController(backend: backend, storage: storage, environmentID: configuration.environmentID,
                                             allowsVerifiedLocalRecording: localRecordingOnly)
        guard let verifier = try? CaptureConnectionVerifier(previewAuth: configuration, target: usesCaptureEdge ? .captureEdge : .account, access: access) else {
            mode = .invalid
            return
        }
        let diagnostics = CaptureConnectionDiagnostics(access: access, check: {
            let revision = access.sessionRevision
            try await verifier.verify()
            if localRecordingOnly { try access.confirmLocalRecording(afterCheckFor: revision) }
        })
        if localRecordingOnly {
            let model = CaptureViewModel(processor: MockCaptureProcessor(), recordingAllowed: { access.canRecordLocally })
            mode = .localRecording(model, access, diagnostics)
        } else {
            mode = .preview(access, diagnostics, usesCaptureEdge: usesCaptureEdge)
        }
    }
}

struct CapturePreviewAuthView: View {
    @ObservedObject var access: CaptureAccessController
    let diagnostics: CaptureConnectionDiagnostics
    let usesCaptureEdge: Bool
    var localRecordingOnly = false
    @State private var acknowledged = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("この版で確認すること") {
                    Text(localRecordingOnly ? "本人確認後、端末内で録音できます。音声は送信せず破棄し、話した内容ではなく固定の訳文を表示します。" : "検証環境でGoogleログインと接続だけを確認します。録音・翻訳・フレーズ保存はできません。")
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
                CaptureConnectionDiagnosticsView(diagnostics: diagnostics, canCheck: access.canRecord, previewOnly: true, previewCaptureEdge: usesCaptureEdge)
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
