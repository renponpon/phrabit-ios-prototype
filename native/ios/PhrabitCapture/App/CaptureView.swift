import PhrabitCaptureCore
import SwiftUI

struct CaptureView: View {
    @ObservedObject var model: CaptureViewModel
    @ObservedObject var access: CaptureAccessController
    var diagnostics: CaptureConnectionDiagnostics? = nil
    @State private var showsAccess = false
    @AccessibilityFocusState private var resultFocused: Bool
    private let background = Color(red: 21 / 255, green: 28 / 255, blue: 45 / 255)
    private let surface = Color(red: 37 / 255, green: 48 / 255, blue: 72 / 255)
    private let lavender = Color(red: 146 / 255, green: 149 / 255, blue: 255 / 255)
    private let mint = Color(red: 121 / 255, green: 242 / 255, blue: 202 / 255)

    var body: some View {
        VStack(spacing: 0) {
            header
            Text(model.isMock ? "模擬翻訳・音声は送信しません" : "音声翻訳・フレーズは保存しません")
                .font(.caption)
                .foregroundStyle(mint)
                .padding(.vertical, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    content
                }
                .frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.top, 32)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            actions
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 20)
        }
        .background(background.ignoresSafeArea())
        .sheet(isPresented: $showsAccess) { CaptureAccessView(access: access, diagnostics: diagnostics) }
        .onChange(of: model.accessSetupRequested) { _, requested in
            if requested { showsAccess = true; model.accessSetupRequested = false }
        }
        .onChange(of: access.userID) { oldUser, newUser in
            if oldUser != nil && oldUser != newUser { model.cancel() }
        }
        .onChange(of: model.session.state) { _, state in
            if case .result = state {
                resultFocused = true
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("icon-512")
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            Text("Phrabit")
                .font(.title2.bold())
            Spacer(minLength: 12)
            Picker("翻訳先", selection: $model.language) {
                ForEach(CaptureLanguage.allCases, id: \.rawValue) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.menu)
            .tint(.white)
            .padding(.horizontal, 8)
            .background(surface, in: Capsule())
            .disabled(model.session.isBusy)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch model.session.state {
        case .idle:
            Text(model.setupComplete ? "話して翻訳" : "最初に一度だけ準備")
                .font(.largeTitle.bold())
            Text("日本語 → \(model.language.displayName)")
                .foregroundStyle(.secondary)
            if !model.setupComplete {
                Text("翻訳先を選び、下のボタンからマイクを許可してください。設定後はロック画面のPhrabitから録音を開始します。")
                    .font(.body)
            }
            Text(model.isMock ? "この試作版では録音だけを行います。話した内容にかかわらず、ホテルの固定サンプルを表示します。" : "話した日本語を翻訳します。音声と認識した文章を外部AIへ送信します。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(model.isMock ? "ログインと送信設定を確認（模擬）" : "ログインと送信設定") { showsAccess = true }
                .frame(minHeight: 44)
            if model.setupComplete {
                VStack(alignment: .leading, spacing: 12) {
                    Text("ロック画面に追加")
                        .font(.headline)
                    Text("ロック画面を長押し → カスタマイズ → ロック画面 → 下部のボタンを変更 → Phrabitを選択 → 完了")
                    Text("配置はiOSで行います。この画面から自動配置はできません。起動時にFace IDなどの認証が入る場合があります。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .background(surface, in: RoundedRectangle(cornerRadius: 20))
            }
        case .preparing:
            Text("マイクを準備しています")
                .font(.title.bold())
            ProgressView()
                .tint(mint)
                .accessibilityLabel("録音準備中")
            Text("録音中の表示と振動を確認してから話してください。")
                .foregroundStyle(.secondary)
        case .recording:
            Text("話してください")
                .font(.largeTitle.bold())
            Text("日本語 → \(model.session.language.displayName)")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Circle()
                    .fill(mint)
                    .frame(width: 12, height: 12)
                Text("録音中")
                    .font(.title3.bold())
            }
            .accessibilityElement(children: .combine)
            if let startedAt = model.recordingStartedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let seconds = min(20, max(0, Int(context.date.timeIntervalSince(startedAt))))
                    Text(String(format: "00:%02d / 00:20", seconds))
                        .font(.title.monospacedDigit())
                        .foregroundStyle(mint)
                }
            }
            Text("話し終えたら停止してください。20秒で自動停止します。")
                .foregroundStyle(.secondary)
        case .recognizing, .translating:
            Text(model.isMock ? "模擬結果を準備中" : model.session.state == .recognizing ? "音声を認識中" : "翻訳中")
                .font(.title.bold())
            ProgressView()
                .tint(mint)
                .accessibilityLabel(model.isMock ? "模擬結果を準備中" : "処理中")
            Text(model.isMock ? "AI・音声認識APIには接続していません。" : "送信済みの処理には料金が発生する場合があります。")
                .foregroundStyle(.secondary)
        case .result(let translation):
            Text(model.isMock ? "サンプル入力・録音内容ではありません" : "認識した日本語")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(translation.sourceText)
                .font(.body)
            VStack(alignment: .leading, spacing: 20) {
                Text(translation.language.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(translation.targetText)
                    .font(.largeTitle.bold())
                    .textSelection(.enabled)
                    .accessibilityFocused($resultFocused)
                if let reading = translation.reading {
                    Text(reading)
                        .font(.title3)
                        .foregroundStyle(mint)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            .background(surface, in: RoundedRectangle(cornerRadius: 24))
            Text(model.isMock ? "録音した音声は破棄します。実翻訳への接続時は、既存PhrabitのGemini翻訳を使用する予定です。" : "音声は認識後に端末から削除します。AIの訳文には誤りが含まれる場合があります。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text("続けられませんでした")
                .font(.title.bold())
            Text(message)
                .foregroundStyle(.yellow)
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 12) {
            switch model.session.state {
            case .recording:
                primaryButton("停止して翻訳", symbol: "stop.fill", action: model.stopAndTranslate)
            case .idle:
                primaryButton(
                    model.setupComplete ? "話す" : "マイクを許可して試す",
                    symbol: "mic.fill",
                    action: model.startRecording
                )
            case .result, .failed:
                primaryButton("もう一度話す", symbol: "mic.fill", action: model.startRecording)
            case .preparing, .recognizing, .translating:
                EmptyView()
            }
            if model.canRetryTranslation {
                Button("翻訳だけ再試行", action: model.retryTranslation)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            if model.session.isBusy {
                Button("キャンセル", action: model.cancel)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(.secondary)
            } else if model.session.state != .idle {
                Button("設定・配置方法", action: model.cancel)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func primaryButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 56)
                .padding(.horizontal, 12)
                .foregroundStyle(background)
                .background(lavender, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }
}

