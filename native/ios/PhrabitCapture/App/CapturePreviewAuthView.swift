import Foundation
import PhrabitCaptureCore
import SwiftUI

@MainActor
final class CapturePreviewAuthLaunch: ObservableObject {
    enum Mode {
        case offline, invalid
        case preview(CaptureAccessController, CaptureConnectionDiagnostics, usesCaptureEdge: Bool)
    }

    let mode: Mode

    init(bundle: Bundle = .main) {
        guard let values = bundle.object(forInfoDictionaryKey: "PhrabitPreviewAuthOnly") else {
            mode = .offline
            return
        }
        guard let settings = values as? [String: String],
              let reference = settings["ProjectRef"], reference.range(of: #"^[a-z]{20}$"#, options: .regularExpression) != nil,
              let key = settings["PublishableKey"], key.hasPrefix("sb_publishable_") else {
            mode = .invalid
            return
        }
        let usesCaptureEdge = settings["ConnectionCheck"] == "capture-edge-v1"
        let expectedKeys: Set<String> = usesCaptureEdge ? ["ProjectRef", "PublishableKey", "ConnectionCheck"] : ["ProjectRef", "PublishableKey"]
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
        let access = CaptureAccessController(backend: backend, storage: storage, environmentID: configuration.environmentID)
        guard let verifier = try? CaptureConnectionVerifier(previewAuth: configuration, target: usesCaptureEdge ? .captureEdge : .account, access: access) else {
            mode = .invalid
            return
        }
        mode = .preview(access, CaptureConnectionDiagnostics(access: access, check: { try await verifier.verify() }), usesCaptureEdge: usesCaptureEdge)
    }
}

struct CapturePreviewAuthView: View {
    @ObservedObject var access: CaptureAccessController
    let diagnostics: CaptureConnectionDiagnostics
    let usesCaptureEdge: Bool
    @State private var acknowledged = false

    var body: some View {
        NavigationStack {
            Form {
                Section("この版で確認すること") {
                    Text("検証環境でGoogleログインと接続だけを確認します。録音・翻訳・フレーズ保存はできません。")
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
            }
            .navigationTitle("Phrabit 接続確認")
            .onChange(of: access.sessionRevision) { _, _ in diagnostics.cancel() }
            .onDisappear { access.cancelSignIn(); diagnostics.cancel() }
        }
    }
}
