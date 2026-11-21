#if PHRABIT_OFFLINE_TRANSLATION_HOME || PHRABIT_PREVIEW_TRANSLATION_HOME
import PhrabitCaptureCore
import SwiftUI
import UIKit

struct TranslationHomeView: View {
    @ObservedObject var model: CaptureViewModel
    @ObservedObject var access: CaptureAccessController
    var diagnostics: CaptureConnectionDiagnostics? = nil
    @Environment(\.openURL) private var openURL
    @FocusState private var editingDraft: Bool
    @AccessibilityFocusState private var resultFocused: Bool
    @State private var draft = ""

    private let background = Color(red: 21 / 255, green: 28 / 255, blue: 45 / 255)
    private let surface = Color(red: 37 / 255, green: 48 / 255, blue: 72 / 255)
    private let accent = Color(red: 157 / 255, green: 161 / 255, blue: 255 / 255)
    private let mint = Color(red: 121 / 255, green: 242 / 255, blue: 202 / 255)
    private let resultID = "translation-home-result"

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(model.isMock ? "オフライン試作 · 訳文は見本" : "本人限定の音声翻訳テスト")
                            .font(.caption)
                            .foregroundStyle(mint)
                        content
                    }
                    .frame(maxWidth: 580)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.session.state) { _, state in
                    if model.session.isBusy { editingDraft = false }
                    if case .result = state {
                        scroll.scrollTo(resultID, anchor: .top)
                        resultFocused = true
                    }
                }
                .onChange(of: model.translationMicrophoneSetup) { _, next in
                    if next != nil { editingDraft = false }
                }
            }
            if model.session.isBusy {
                busyActions
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
        }
        .background(background.ignoresSafeArea())
        .tint(accent)
        .sheet(isPresented: $model.accessSetupRequested) {
            if !model.isMock {
                CaptureAccessView(access: access, diagnostics: diagnostics, audioPilot: true)
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Phrabit").font(.caption.bold()).foregroundStyle(.secondary)
                Text("翻訳").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            }
            Spacer()
            Picker("翻訳先", selection: $model.language) {
                ForEach(CaptureLanguage.allCases, id: \.self) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.menu)
            .disabled(model.session.isBusy || model.translationMicrophoneSetup != nil)
            .frame(minHeight: 44)
            .padding(.horizontal, 8)
            .background(surface, in: Capsule())
            if !model.isMock {
                Button {
                    editingDraft = false
                    model.accessSetupRequested = true
                } label: {
                    Image(systemName: "gearshape").frame(width: 44, height: 44)
                }
                .accessibilityLabel("ログインと送信設定")
                .disabled(model.session.isBusy)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch model.session.state {
        case .preparing:
            statusCard("マイクを準備中", detail: "「録音中」が表示されてから話してください。", showsProgress: true)
        case .recording:
            VStack(alignment: .leading, spacing: 16) {
                Label("録音中", systemImage: "waveform")
                    .font(.title.bold())
                    .foregroundStyle(mint)
                    .accessibilityAddTraits(.isHeader)
                Text("話し終えたら「停止して翻訳」を押してください。")
                if let started = model.recordingStartedAt {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        let elapsed = min(20, max(0, Int(context.date.timeIntervalSince(started))))
                        Text("\(elapsed)秒 / 20秒")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityHidden(true)
                }
                Text(model.isMock ? "音声は端末外へ送信されません。20秒で録音を破棄します。" :
                     "「停止して翻訳」を押したときだけ、録音をOpenAIへ、認識文をGoogleのGeminiへ送ります。20秒で録音を破棄します。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(surface, in: RoundedRectangle(cornerRadius: 22))
        case .recognizing:
            statusCard(model.isMock ? "見本を準備中" : "文字起こし中",
                       detail: model.isMock ? "入力や音声は送信していません。" : "音声を文字に変換しています。", showsProgress: true)
        case .translating:
            statusCard(model.isMock ? "見本を準備中" : "翻訳中",
                       detail: model.isMock ? "入力や音声は送信していません。" : "認識した日本語を翻訳しています。", showsProgress: true)
        case .idle, .result, .failed:
            if let setup = model.translationMicrophoneSetup { microphoneNotice(setup) }
            composer
            if case .result(let translation) = model.session.state { resultCard(translation).id(resultID) }
            if case .failed(let message) = model.session.state, model.translationMicrophoneSetup == nil {
                statusCard(message, detail: "入力中の文章はそのままです。", showsProgress: false)
            }
        }
    }

    private var composer: some View {
        let count = draft.utf16.count
        return VStack(alignment: .leading, spacing: 10) {
            Text("日本語").font(.subheadline.bold()).foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("日本語を入力").foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextEditor(text: $draft)
                    .scrollContentBackground(.hidden)
                    .background(.clear)
                    .font(.body)
                    .frame(minHeight: 104)
                    .focused($editingDraft)
                    .accessibilityLabel("日本語の入力")
            }
            HStack {
                if model.isMock && draft.isEmpty {
                    Button("例文を入れる") { draft = MockTranslator.sample(for: .chinese).sourceText }
                        .font(.footnote)
                        .frame(minHeight: 44)
                }
                Spacer()
                Text("\(count) / \(CaptureTranslationHomeRules.inputLimit)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(count > CaptureTranslationHomeRules.inputLimit ? Color.orange : Color.secondary)
            }
            HStack(spacing: 12) {
                Button {
                    editingDraft = false
                    model.requestTranslationHomeRecording()
                } label: {
                    Label("音声", systemImage: "mic")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .disabled(model.translationMicrophoneSetup != nil)

                if model.isMock {
                    Button {
                        editingDraft = false
                        model.submitTranslationDraft(draft)
                    } label: {
                        Text("翻訳").frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(background)
                    .disabled(model.translationMicrophoneSetup != nil || CaptureTranslationHomeRules.validatedText(draft) == nil)
                }
            }
            if !model.isMock {
                Text("この検証版は音声翻訳のみ。入力欄の下書きは送信しません。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(surface, in: RoundedRectangle(cornerRadius: 22))
    }

    private func microphoneNotice(_ setup: CaptureTranslationHomeRules.MicrophoneEntry) -> some View {
        let needsSettings = setup == .settingsRequired
        return VStack(alignment: .leading, spacing: 10) {
            Text(needsSettings ? "マイクが許可されていません" : "初回だけマイクの許可が必要です")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(needsSettings
                 ? "設定でマイクを許可し、戻ってから「音声」を押してください。"
                 : "許可したあとは、ロック画面のPhrabitボタンからそのまま録音できます。")
                .font(.callout)
            Button(needsSettings ? "iPhoneの設定を開く" : "マイクを許可して録音") {
                if needsSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                } else if !needsSettings {
                    model.allowMicrophoneAndRecord()
                }
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(background)
            Button("今はしない", action: model.cancel).frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private var busyActions: some View {
        VStack(spacing: 8) {
            if case .recording = model.session.state {
                Button(action: model.stopAndTranslate) {
                    Label("停止して翻訳", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(background)
            }
            Button("キャンセル", action: model.cancel).frame(minHeight: 44)
        }
        .frame(maxWidth: 580)
    }

    private func resultCard(_ translation: CaptureTranslation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.isMock {
                Text("認識した日本語").font(.subheadline.bold()).foregroundStyle(.secondary)
                Text(translation.sourceText).textSelection(.enabled)
            }
            Text(model.isMock ? "\(translation.language.displayName)の訳文サンプル" : "\(translation.language.displayName)の訳文")
                .font(.subheadline.bold()).foregroundStyle(.secondary)
            Text(translation.targetText)
                .font(.title.bold())
                .textSelection(.enabled)
                .accessibilityFocused($resultFocused)
            if let reading = translation.reading {
                Text(reading).font(.body).foregroundStyle(mint).textSelection(.enabled)
            }
            Text(model.isMock ? "入力・録音内容の翻訳ではありません。" : "大切な内容は訳文を確認してください。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(surface, in: RoundedRectangle(cornerRadius: 22))
    }

    private func statusCard(_ title: String, detail: String, showsProgress: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if showsProgress { ProgressView().accessibilityLabel(title) }
            Text(detail).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(surface, in: RoundedRectangle(cornerRadius: 22))
    }
}
#endif
