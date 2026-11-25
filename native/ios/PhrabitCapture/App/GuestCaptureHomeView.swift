#if PHRABIT_OFFLINE_GUEST_TESTFLIGHT || (DEBUG && (PHRABIT_OFFLINE_GUEST_HOME || PHRABIT_OFFLINE_TRANSLATION_HOME))
import AVFAudio
import Combine
import Foundation
import PhrabitCaptureCore
import SwiftUI
import UIKit

@MainActor
private final class GuestPreviewConsent: ObservableObject {
    private static let key = "phrabit.offline.guest-preview.consent.v1"
    @Published private(set) var allowed: Bool

    init() { allowed = UserDefaults.standard.bool(forKey: Self.key) }

    func setAllowed(_ value: Bool) {
        allowed = value
        UserDefaults.standard.set(value, forKey: Self.key)
    }
}

@MainActor
private final class GuestPreviewProcessor: ObservableObject, CaptureProcessing {
    let sendsAudio = false
    @Published private(set) var fixture: GuestCaptureFixture
    @Published private(set) var feedback: GuestCaptureFeedback?
    #if DEBUG && PHRABIT_GUEST_DEVICE_MOCK
    private let deviceCheck = GuestMockDeviceCheck()
    #endif

    init() { fixture = Self.makeFixture(issue: nil) }

    private static func makeFixture(issue: GuestCaptureFeedback?) -> GuestCaptureFixture {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let now = Date()
        let reset = utc.dateInterval(of: .day, for: now)?.end ?? now
        let quota = GuestQuotaSnapshot(remaining: issue == .daily ? 0 : 2, nextReset: reset)
        return GuestCaptureFixture(response: quota, issue: issue)
    }

    func simulate(_ issue: GuestCaptureFeedback?) {
        fixture = Self.makeFixture(issue: issue)
        feedback = nil
    }

    func beginRecording() -> Bool {
        if fixture.quota.nextReset <= Date() { simulate(fixture.simulatedIssue) }
        feedback = fixture.quota.remaining == 0 ? .daily : nil
        return feedback == nil
    }

    func clearFeedback() { feedback = nil }

    func transcribe(audio: Data, durationMilliseconds: Int, sessionID: UUID) async throws -> String {
        try Task.checkCancellation()
        guard audio.isEmpty else { throw CaptureClientError.invalidInput }
        do {
            #if DEBUG && PHRABIT_GUEST_DEVICE_MOCK
            try fixture.checkAvailable(sessionID)
            do {
                try await deviceCheck.verifyBeforeMockTranslation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw GuestCaptureFeedback.deviceCheck
            }
            try Task.checkCancellation()
            #endif
            try fixture.attempt(sessionID)
        } catch let issue as GuestCaptureFeedback {
            feedback = issue
            throw issue
        }
        return MockTranslator.sample(for: .chinese).sourceText
    }

    func translate(text: String, to language: CaptureLanguage, sessionID: UUID) async throws -> CaptureTranslation {
        try await MockTranslator().translate(to: language)
    }
}

@MainActor
struct GuestCaptureHomeView: View {
    private enum Step: Equatable { case consent, microphone, placement, settings, sample }

    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL
    @AppStorage("phrabit.offline.guest-preview.guide-seen.v1") private var placementSeen = false
    @StateObject private var consent: GuestPreviewConsent
    @StateObject private var processor: GuestPreviewProcessor
    @StateObject private var model: CaptureViewModel
    @State private var step: Step?
    @State private var requesting = false
    @State private var permission: CaptureTranslationHomeRules.MicrophonePermission

    init() {
        let consent = GuestPreviewConsent()
        let processor = GuestPreviewProcessor()
        _consent = StateObject(wrappedValue: consent)
        _processor = StateObject(wrappedValue: processor)
        _permission = State(initialValue: Self.currentPermission)
        _model = StateObject(wrappedValue: CaptureViewModel(
            processor: processor,
            recordingAllowed: { consent.allowed && Self.currentPermission == .allowed },
            recordingDuration: GuestCaptureFixture.maximumRecordingDuration
        ))
    }

    private static var currentPermission: CaptureTranslationHomeRules.MicrophonePermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .allowed
        case .undetermined: return .notRequested
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    #if DEBUG && PHRABIT_GUEST_DEVICE_MOCK
                    Text("端末確認・翻訳は模擬 · 外部に送信しません")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                    #else
                    Text("試作 · 外部に送信しません")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                    #endif
                    if let step { setupView(step) } else { captureView }
                }
                .padding(20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Phrabit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("設定", systemImage: "gearshape") { step = .settings }
                        .disabled(model.session.isBusy || requesting)
                }
            }
        }
        .task { handleLockScreen() }
        .onReceive(NotificationCenter.default.publisher(for: CaptureLaunchRequest.notification)) { _ in
            handleLockScreen()
        }
        .onChange(of: phase) { _, next in
            switch next {
            case .active:
                permission = Self.currentPermission
                if step == .microphone && permission == .allowed && consent.allowed && !requesting { nextAfterPermission() }
                handleLockScreen()
            case .background:
                model.stopForBackground()
            default: break
            }
        }
        .onChange(of: model.accessSetupRequested) { _, requested in
            guard requested else { return }
            model.accessSetupRequested = false
            permission = Self.currentPermission
            step = consent.allowed ? .microphone : .consent
        }
    }

    @ViewBuilder
    private func setupView(_ page: Step) -> some View {
        switch page {
        case .consent:
            title("音声を翻訳する前に", detail: "実接続版では、「停止して翻訳」を押したときだけ翻訳に必要なデータを送信します。この試作は送信しません。")
            LabeledContent("録音した音声", value: "OpenAIで文字起こし")
            LabeledContent("認識した日本語", value: "Geminiで翻訳")
            Text("同意は設定でいつでも取り消せます。").foregroundStyle(.secondary)
            primary("同意して進む") {
                consent.setAllowed(true)
                permission = Self.currentPermission
                if permission == .allowed { nextAfterPermission() } else { step = .microphone }
            }
            Button("同意せずに戻る") { step = nil }
        case .microphone:
            if permission == .denied {
                title("マイクがオフになっています", detail: "iPhoneの設定でPhrabitのマイクをオンにしてください。")
                primary("設定を開く") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            } else {
                title("マイクの使用を許可", detail: "日本語を録音するために使います。許可するだけでは音声は送信されません。")
                primary("マイクを許可する", action: requestMicrophone)
                    .disabled(requesting)
            }
            Button("音声を送らず見本を見る") { step = .sample }.disabled(requesting)
        case .placement:
            title("ロック画面に追加", detail: "追加はiPhone側で行います。アプリからも録音できるので、後回しにできます。")
            Text("1. ロック画面を長押しし、「カスタマイズ」を選びます。")
            Text("2. 下部で入れ替えるボタンを外し、「＋」を押します。")
            Text("3. 「Phrabit」を選び、「完了」を押します。")
            primary("アプリの翻訳画面へ", action: dismissPlacement)
            Button("あとで追加する", action: dismissPlacement)
        case .settings:
            title("設定", detail: consent.allowed ? "音声送信の説明に同意済み" : "音声送信への同意なし")
            Button("ロック画面への追加方法") { step = .placement }
            if consent.allowed {
                Button("音声送信の同意を取り消す", role: .destructive) {
                    model.cancel()
                    consent.setAllowed(false)
                    processor.clearFeedback()
                    step = nil
                }
            }
            Picker("模擬応答", selection: Binding(
                get: { processor.fixture.simulatedIssue },
                set: { issue in model.cancel(); processor.simulate(issue) }
            )) {
                Text("正常").tag(nil as GuestCaptureFeedback?)
                ForEach(GuestCaptureFeedback.allCases, id: \.rawValue) { issue in
                    Text(issue.title).tag(Optional(issue))
                }
            }
            primary("戻る") { step = nil }
        case .sample:
            result(MockTranslator.sample(for: model.language), title: "音声を送らない見本")
            primary("戻る") { step = nil }
        }
    }

    @ViewBuilder
    private var captureView: some View {
        if !consent.allowed {
            title("ロック画面から話して翻訳", detail: "日本語を英語や中国語へ。アカウント登録は不要です。")
            primary("はじめる") { step = .consent }
            Button("音声を送らず見本を見る") { step = .sample }
        } else if let issue = processor.feedback {
            title(issue.title, detail: feedbackDetails(issue))
            Text(issue.consumesAttempt ? "実接続ならこの試行は1回分です。この試作では送信していません。" : "音声は送信していません。")
                .font(.callout)
            primary("翻訳画面へ戻る") { model.cancel(); processor.clearFeedback() }
            Button("音声を送らず見本を見る") {
                model.cancel()
                processor.clearFeedback()
                step = .sample
            }
        } else {
            switch model.session.state {
            case .idle:
                title("話して翻訳", detail: "日本語から翻訳")
                Picker("翻訳先", selection: $model.language) {
                    ForEach(CaptureLanguage.allCases, id: \.rawValue) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.segmented)
                quotaSummary
                primary("話す", action: requestRecording)
                Button("ロック画面への追加方法") { step = .placement }
            case .preparing:
                ProgressView("録音の準備中")
                Button("キャンセル", action: model.cancel)
            case .recording:
                title("録音中", detail: "15秒以内に停止してください。この試作では音声を外部に送りません。")
                primary("停止して翻訳", action: model.stopAndTranslate)
                Button("キャンセル", action: model.cancel)
            case .recognizing, .translating:
                #if DEBUG && PHRABIT_GUEST_DEVICE_MOCK
                ProgressView("端末確認と翻訳を模擬検証しています")
                #else
                ProgressView("見本を表示しています")
                #endif
                Button("キャンセル", action: model.cancel)
            case .result(let translation):
                result(translation, title: "訳文の見本")
                quotaSummary
                primary("戻る", action: model.cancel)
            case .failed(let message):
                title("録音を完了できませんでした", detail: message)
                primary("翻訳画面へ戻る", action: model.cancel)
            }
        }
    }

    private var quotaSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("残り \(processor.fixture.quota.remaining) 回（模擬）")
            Text("次の更新 \(processor.fixture.quota.nextReset.formatted(date: .abbreviated, time: .shortened))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func title(_ text: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text(detail).foregroundStyle(.secondary)
        }
    }

    private func primary(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(text).frame(maxWidth: .infinity, minHeight: 30) }
            .buttonStyle(.borderedProminent)
    }

    private func result(_ translation: CaptureTranslation, title: String) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title).font(.headline)
            Text(translation.sourceText).foregroundStyle(.secondary)
            Text(translation.language.displayName).font(.caption)
            Text(translation.targetText).font(.title2.bold())
            if let reading = translation.reading { Text(reading).foregroundStyle(.mint) }
        }
    }

    private func feedbackDetails(_ issue: GuestCaptureFeedback) -> String {
        switch issue {
        case .daily:
            return "次の更新は \(processor.fixture.quota.nextReset.formatted(date: .abbreviated, time: .shortened)) です。"
        case .serviceBudget: return "Phrabit全体の利用枠に達しました。あなたの利用回数は減っていません。"
        case .offline: return "通信が戻ってから、もう一度話してください。今回は利用回数を使っていません。"
        case .deviceCheck: return "通信とアプリの更新を確認してください。確認できない間も、見本は利用できます。"
        case .burst: return "短時間に操作が集中したため、一時的に停止しました。"
        case .provider: return "時間をおいて、新しく録音してください。自動では再送しません。"
        }
    }

    private func dismissPlacement() {
        placementSeen = true
        step = nil
    }

    private func nextAfterPermission() {
        step = placementSeen ? nil : .placement
    }

    private func requestMicrophone() {
        guard consent.allowed, !requesting else { return }
        requesting = true
        AVAudioApplication.requestRecordPermission { _ in
            Task { @MainActor in
                requesting = false
                permission = Self.currentPermission
                if step == .microphone && permission == .allowed && consent.allowed { nextAfterPermission() }
            }
        }
    }

    private func requestRecording() {
        guard model.isMock, !model.session.isBusy, !requesting else { return }
        permission = Self.currentPermission
        switch GuestCaptureEntry(consent: consent.allowed, permission: permission) {
        case .consent: step = .consent
        case .microphone, .microphoneSettings: step = .microphone
        case .record:
            step = nil
            if processor.beginRecording() { model.startRecording() }
        }
    }

    private func handleLockScreen() {
        guard phase == .active, CaptureLaunchRequest.consume() else { return }
        requestRecording()
    }
}
#endif
