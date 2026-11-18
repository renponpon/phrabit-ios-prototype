import PhrabitCaptureCore
import SwiftUI

struct CaptureAccessView: View {
    @ObservedObject var access: CaptureAccessController
    var diagnostics: CaptureConnectionDiagnostics? = nil
    @State private var acknowledged = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(access.isMock ? "模擬設定・実際のログインや送信はしません" : "初回だけの接続設定")
                        .font(.headline)
                    Text("翻訳のため、録音をOpenAIへ、認識した日本語をGoogleのGeminiへPhrabit経由で送ります。")
                    Text("録音は認識後に端末から削除し、フレーズ・ドリルには保存しません。処理事業者側の保持がゼロという意味ではありません。AIの誤認識・誤訳があるため、大切な内容は確認してください。")
                        .font(.footnote)
                } header: { Text("1. 音声と認識文の送信") }

                if !access.consentAccepted {
                    Section {
                        Toggle("送信先と注意事項を確認しました", isOn: $acknowledged)
                        Button(access.isMock ? "同意の動作を確認" : "同意して続ける", action: access.acceptConsent)
                            .disabled(!acknowledged || access.isBusy)
                    }
                } else {
                    Section {
                        Label("送信先を確認済み", systemImage: "checkmark.circle")
                        switch access.state {
                        case .signingIn:
                            ProgressView(access.isMock ? "模擬ログイン中" : "Googleでログイン中")
                            Button("ログインを中止", action: access.cancelSignIn)
                        case .signedIn:
                            Label(access.isMock ? "ログイン済み（模擬）" : "ログイン済み", systemImage: "person.crop.circle.badge.checkmark")
                            Text("メールアドレスはこの画面に表示しません。")
                                .font(.footnote)
                            Button("この端末からログアウト", action: access.clearSession)
                        default:
                            Button(access.isMock ? "模擬ログインを試す" : "Googleでログイン", action: access.signIn)
                        }
                        Button("送信同意を取り消す", role: .destructive, action: access.withdrawConsent)
                            .disabled(access.isBusy)
                    } header: { Text("2. Phrabitのアカウント") }
                    Text("Apple・TestFlightのアカウントとは別です。Phrabitで使うGoogleアカウントを選んでください。")
                        .font(.footnote)
                }

                if case .failed(let message) = access.state {
                    Section { Text(message).foregroundStyle(.red) }
                }
                if let diagnostics {
                    CaptureConnectionDiagnosticsView(diagnostics: diagnostics, canCheck: access.canRecord)
                }
                Section {
                    Text("設定後はロック画面のPhrabitから録音できます。録音開始前にログイン更新の通信を待ちません。期限切れなどで再ログインが必要な場合は案内します。")
                    NavigationLink("データの取り扱い") {
                        Form {
                            Section("送信先と目的") {
                                Text("実接続版では、録音をOpenAIで文字起こしし、その文章をGoogleのGeminiで翻訳します。いずれもPhrabitのサーバー経由です。")
                            }
                            Section("端末とサーバーの記録") {
                                Text("録音は端末の一時ファイルへ置き、認識後に削除します。強制終了時は次回起動で削除します。認識文と訳文は画面の一時メモリだけで、保存フレーズやドリルに追加しません。認証情報は端末内Keychainへ保存し、サーバーでは利用量・予算などの管理記録を残します。")
                            }
                            Section("注意点") {
                                Text("外部の処理事業者による保持がゼロという意味ではありません。大切な個人情報や秘密の入力は避けてください。AIの認識・訳文には誤りがあり、送信後に中断しても開始済みの処理・料金は取り消せないことがあります。")
                                Text("現在の模擬版は外部に接続しません。実環境の設定・公開前には、プライバシー案内と利用条件を別途確認します。")
                            }
                        }.navigationTitle("データの取り扱い")
                    }
                }
            }
            .navigationTitle("ログインと送信設定")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { access.cancelSignIn(); dismiss() } } }
            .interactiveDismissDisabled(access.isBusy)
            .onChange(of: access.sessionRevision) { _, _ in diagnostics?.cancel() }
            .onDisappear { access.cancelSignIn(); diagnostics?.cancel() }
        }
    }
}

struct CaptureConnectionDiagnosticsView: View {
    @ObservedObject var diagnostics: CaptureConnectionDiagnostics
    let canCheck: Bool
    var previewOnly = false
    var previewCaptureEdge = false

    var body: some View {
        Section {
            switch diagnostics.state {
            case .checking:
                ProgressView("接続を確認中")
                Button("確認を中止", action: diagnostics.cancel)
            case .ready:
                Label(previewCaptureEdge ? "検証用APIに接続できました（音声未送信）" : "接続確認OK（音声未送信）", systemImage: "checkmark.circle")
            case .failed(let message):
                Text(message).foregroundStyle(.red)
            case .idle:
                EmptyView()
            }
            Button("接続を確認（音声を送らない）", action: diagnostics.run)
                .disabled(!canCheck || diagnostics.isBusy)
            Text(previewCaptureEdge ? "ログインした本人が検証用APIに接続できるか確認します。音声・翻訳・学習データは送りません。" : previewOnly ? "Previewの認証サーバーに接続し、ログイン中のアカウントか確認します。音声・翻訳・学習データは送りません。" : "認証だけを確認します。録音・翻訳・フレーズ保存・学習日の記録は行いません。録音開始前に自動実行しません。")
                .font(.footnote)
        } header: { Text("接続確認") }
    }
}
