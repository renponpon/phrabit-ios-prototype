import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main
@MainActor
struct PhrabitGuestDeviceProbeApp: App {
    var body: some Scene {
        WindowGroup { GuestDeviceProbeView() }
    }
}

@MainActor
private struct GuestDeviceProbeView: View {
    @Environment(\.openURL) private var openURL
    @StateObject private var exchange = GuestProbeBrowserExchange()
    @State private var address = ""
    @State private var fingerprint: String?
    @State private var savedPhase: GuestAttestKey.Phase?
    @State private var status = ""
    @State private var running: Task<Void, Never>?
    private let keyStore = KeychainGuestAttestKeyStore()

    private enum Action {
        case prepare, enroll, confirm
    }

    private var previewURL: URL? {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"\Ahttps://phrabit-ios-guest-preview-[a-z0-9]{9,16}-renponpons-projects\.vercel\.app/api/ios/guest/device-test\z"#
        guard value.utf8.count <= 140, value.range(of: pattern, options: .regularExpression) != nil,
              let url = URL(string: value), url.absoluteString == value else { return nil }
        return url
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("本人用の端末確認です。録音・翻訳・音声送信は行いません。")
                    Button("端末キーを準備") { run(.prepare) }
                        .disabled(running != nil)
                    if let fingerprint {
                        Button("キー指紋をコピー") { copy(fingerprint, for: 600) }
                        Text("検証枠を用意する担当者にはキー指紋だけを渡してください。")
                            .font(.footnote)
                    }
                } header: { Text("1. キーを準備") }

                Section {
                    TextField("案内された検証ページURL", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("ブラウザで検証ページを開く") {
                        if let previewURL { openURL(previewURL) }
                    }
                    .disabled(previewURL == nil)
                    Button("初回登録を始める") { run(.enroll) }
                        .disabled(savedPhase != .allocated || previewURL == nil || running != nil)
                    Button("同じキーで再確認") { run(.confirm) }
                        .disabled(savedPhase == nil || savedPhase == .allocated || previewURL == nil || running != nil)
                } header: { Text("2. 登録・再確認") }

                if let request = exchange.pending {
                    Section {
                        Text(request.path.hasSuffix("/challenge") ? "確認のためのチャレンジを受け取ります。" : "Appleの端末確認データを送り、結果を受け取ります。")
                        Button("確認データをコピー") {
                            if let value = exchange.copyableRequest() { copy(value, for: 110) }
                        }
                        Text("ブラウザの「アプリの確認データ」へ貼り付けて送信し、結果をコピーして戻ります。")
                            .font(.footnote)
                        PasteButton(payloadType: String.self) { items in
                            if let value = items.first, exchange.accept(value) {
                                status = "結果を確認しています…"
                            } else {
                                status = "今回の結果ではありません。ブラウザで最新の結果をコピーしてください。"
                            }
                        }
                        .accessibilityLabel("結果を貼り付け")
                    } header: { Text("3. 検証ページとのやり取り") }
                }

                if running != nil {
                    Button("中止", role: .cancel) {
                        running?.cancel()
                        exchange.cancel()
                    }
                }
                if !status.isEmpty {
                    Text(status)
                        .accessibilityIdentifier("deviceCheckStatus")
                }
            }
            .navigationTitle("Phrabit 端末確認")
            .onAppear { refreshSavedState() }
        }
    }

    private func refreshSavedState() {
        do {
            let saved = try keyStore.read()
            savedPhase = saved?.phase
            fingerprint = try saved?.fingerprint()
        } catch {
            status = "保存した端末キーを読み取れませんでした。"
        }
    }

    private func copy(_ text: String, for seconds: TimeInterval) {
        UIPasteboard.general.setItems([[UTType.plainText.identifier: text]], options: [
            .localOnly: true, .expirationDate: Date().addingTimeInterval(seconds)
        ])
    }

    private func run(_ action: Action) {
        guard running == nil else { return }
        let api = GuestCheckJSONAPI(exchange: exchange.send)
        let flow = GuestDeviceCheckFlow(provider: AppleGuestAttest(), keyStore: keyStore, api: api)
        status = "処理中…"
        running = Task { @MainActor in
            defer {
                refreshSavedState()
                running = nil
            }
            do {
                switch action {
                case .prepare:
                    fingerprint = try await flow.prepare()
                    status = "この端末のキーを準備しました。"
                case .enroll:
                    try await flow.enroll()
                    status = "初回登録の結果を受け取りました。アプリを終了して開き直し、再確認してください。"
                case .confirm:
                    try await flow.confirm()
                    status = "同じキーで再確認できました。"
                }
            } catch is CancellationError {
                status = "中止しました。キーは作り直しません。"
            } catch GuestDeviceCheckError.unsupported {
                status = "この端末ではApp Attestを利用できません。"
            } catch {
                status = "確認できませんでした。キーを作り直さず、検証ページの表示を確認してください。"
            }
        }
    }
}
