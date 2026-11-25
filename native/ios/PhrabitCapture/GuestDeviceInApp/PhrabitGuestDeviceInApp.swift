import Foundation
import SwiftUI
import WebKit

@main
@MainActor
struct PhrabitGuestDeviceInApp: App {
    var body: some Scene {
        WindowGroup { GuestInAppDeviceView() }
    }
}

@MainActor
private struct GuestInAppDeviceView: View {
    @StateObject private var browser = GuestInAppBrowser()
    @State private var address = ""
    @State private var shortCode = ""
    @State private var showingPreview = false
    @State private var canUseSavedKey = false
    @State private var checking = false
    @State private var status = ""
    private let keyStore = KeychainGuestAttestKeyStore()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("本人用の検証です。録音・翻訳・音声送信は行いません。")
                    if !canUseSavedKey {
                        Text("登録済みの端末キーを読み取れません。キーは作り直さず、担当者にお知らせください。")
                    }
                    TextField("案内された検証ページURL", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .disabled(checking)
                        .onChange(of: address) { shortCode = "" }
                    Button("保護された検証ページを開く") {
                        if let page = GuestInAppWebRequest.page(address) {
                            browser.open(page)
                            showingPreview = true
                        }
                    }
                    .disabled(GuestInAppWebRequest.page(address) == nil || checking)
                } header: { Text("検証先") }

                Section {
                    SecureField("案内された検証コード", text: $shortCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(checking)
                    Button("同じキーで再確認（音声を送らない）") { confirm() }
                        .disabled(!canUseSavedKey || !browser.isReady || checking ||
                                  browser.webView.url != GuestInAppWebRequest.page(address) ||
                                  GuestInAppWebRequest.code(shortCode) == nil)
                    if !status.isEmpty {
                        Text(status).accessibilityIdentifier("deviceCheckStatus")
                    }
                } header: { Text("端末確認") }
            }
            .navigationTitle("Phrabit 端末確認")
            .onAppear {
                canUseSavedKey = (try? keyStore.read()).map { $0.phase == .registered } ?? false
            }
            .onChange(of: browser.isReady) {
                if browser.isReady { showingPreview = false }
            }
            .sheet(isPresented: $showingPreview) {
                NavigationStack {
                    GuestInAppBrowserView(webView: browser.webView)
                        .safeAreaInset(edge: .top) {
                            if browser.isLoading {
                                ProgressView("検証ページを読み込んでいます").padding()
                            } else if browser.failed {
                                Text("検証ページを開けませんでした。ログインや検証先を担当者に確認してください。")
                                    .padding()
                            } else if !browser.isReady {
                                Text("Vercelの画面です。検証用アカウントでアクセスしてください。")
                                    .padding()
                            }
                        }
                        .navigationTitle("本人用Preview")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("閉じる") { showingPreview = false }
                            }
                        }
                }
            }
        }
    }

    private func confirm() {
        guard !checking, canUseSavedKey, let code = GuestInAppWebRequest.code(shortCode),
              let page = GuestInAppWebRequest.page(address), browser.webView.url == page, browser.isReady else { return }
        shortCode = ""
        checking = true
        status = "端末キーを確認しています…"
        Task { @MainActor in
            defer { checking = false }
            let api = GuestCheckJSONAPI { route, data in
                try await browser.send(route, data, code: code)
            }
            let flow = GuestDeviceCheckFlow(provider: AppleGuestAttest(), keyStore: keyStore, api: api)
            do {
                try await flow.confirm()
                status = "同じキーで再確認できました。"
            } catch GuestDeviceCheckError.unsupported {
                status = "この端末ではApp Attestを利用できません。"
            } catch {
                status = "確認できませんでした。キーは作り直さず、担当者にお知らせください。"
            }
        }
    }
}

private struct GuestInAppBrowserView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
