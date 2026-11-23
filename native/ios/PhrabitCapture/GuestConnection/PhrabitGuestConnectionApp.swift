import Foundation
import SwiftUI

@main
struct PhrabitGuestConnectionApp: App {
    var body: some Scene {
        WindowGroup {
            GuestConnectionView()
        }
    }
}

private struct GuestConnectionView: View {
    @Environment(\.openURL) private var openURL
    @State private var address = ""
    @State private var browserUnavailable = false

    private var verifiedURL: URL? { GuestConnectionURL.validated(address) }

    var body: some View {
        NavigationStack {
            Form {
                Section("録音しない接続確認") {
                    Text("この検証版は、録音・翻訳・保存を行いません。")
                    TextField("案内された検証URL", text: $address, axis: .vertical)
                        .accessibilityLabel("検証URL")
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(2...4)
                    if !address.isEmpty && verifiedURL == nil {
                        Text("案内された専用PreviewのURLを貼り付けてください。")
                            .foregroundStyle(.secondary)
                    }
                    Button("ブラウザで接続確認") {
                        guard let url = verifiedURL else { return }
                        openURL(url) { accepted in
                            browserUnavailable = !accepted
                        }
                    }
                    .disabled(verifiedURL == nil)
                }
                Section("確認方法") {
                    Text("Vercelへのログインが必要な場合はブラウザで行います。Phrabitのログインは不要です。")
                    Text("短期コードは、専用Previewの確認ページでだけ入力します。結果もブラウザに表示されます。")
                }
            }
            .navigationTitle("Phrabit 接続確認")
            .alert("ブラウザを開けませんでした", isPresented: $browserUnavailable) {
                Button("閉じる", role: .cancel) {}
            }
        }
    }
}
