import Combine
import Foundation
import PhrabitCaptureCore
import UIKit

@MainActor
final class CaptureViewModel: ObservableObject {
    @Published private(set) var session = CaptureSession()
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var setupComplete: Bool
    @Published var language: CaptureLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey)
            if oldValue != language { cancel() }
        }
    }

    private static let languageKey = "phrabit.quickcapture.language"
    private static let setupKey = "phrabit.quickcapture.setup"
    private let recorder = AudioRecorder()
    private let processor: any CaptureProcessing
    private let recordingAllowed: () -> Bool
    private let authenticationRequired: () -> Void
    @Published var accessSetupRequested = false
    @Published private(set) var recognizedText: String?
    #if PHRABIT_OFFLINE_TRANSLATION_HOME || PHRABIT_PREVIEW_TRANSLATION_HOME
    @Published private(set) var translationMicrophoneSetup: CaptureTranslationHomeRules.MicrophoneEntry?
    #endif
    #if PHRABIT_OFFLINE_STARTUP_TIMING
    private(set) var startupTiming: CaptureStartupTiming?
    #endif
    private var uploadMayHaveStarted = false
    private var operationTask: Task<Void, Never>?

    var isMock: Bool { !processor.sendsAudio }
    var canRetryTranslation: Bool {
        if isMock, case .failed = session.state { return recognizedText != nil }
        return false
    }

    init(processor: (any CaptureProcessing)? = nil, recordingAllowed: @escaping () -> Bool = { true }, authenticationRequired: @escaping () -> Void = {}) {
        self.processor = processor ?? MockCaptureProcessor()
        self.recordingAllowed = recordingAllowed
        self.authenticationRequired = authenticationRequired
        language = CaptureLanguage(rawValue: UserDefaults.standard.string(forKey: Self.languageKey) ?? "") ?? .chinese
        setupComplete = UserDefaults.standard.bool(forKey: Self.setupKey)
        recorder.onTimeLimit = { [weak self] in
            guard let self else { return }
            #if PHRABIT_OFFLINE_TRANSLATION_HOME || PHRABIT_PREVIEW_TRANSLATION_HOME
            self.recordingFailed("20秒に達したため録音を破棄しました。")
            #else
            if self.isMock {
                self.stopAndTranslate()
            } else {
                self.recordingFailed("20秒に達したため録音を破棄しました。音声は送信していません。")
            }
            #endif
        }
        recorder.onInterruption = { [weak self] in
            self?.recordingFailed("通話などで録音が中断されました。もう一度話してください。")
        }
        recorder.onFailure = { [weak self] in
            self?.recordingFailed("録音を完了できませんでした。もう一度試してください。")
        }
    }

    func handlePendingLaunch() {
        #if PHRABIT_OFFLINE_STARTUP_TIMING
        var intentUptime: TimeInterval?
        guard CaptureLaunchRequest.consume(onIntentUptime: { intentUptime = $0 }), !session.isBusy else { return }
        #else
        guard CaptureLaunchRequest.consume(), !session.isBusy else { return }
        let intentUptime: TimeInterval? = nil
        #endif
        #if PHRABIT_OFFLINE_TRANSLATION_HOME || PHRABIT_PREVIEW_TRANSLATION_HOME
        requestTranslationHomeRecording()
        #else
        guard recordingAllowed() else { accessSetupRequested = true; return }
        if setupComplete {
            beginRecording(intentUptime: intentUptime)
        }
        #endif
    }

    #if PHRABIT_OFFLINE_TRANSLATION_HOME || PHRABIT_PREVIEW_TRANSLATION_HOME
    func requestTranslationHomeRecording() {
        guard !session.isBusy, !accessSetupRequested else { return }
        let entry = CaptureTranslationHomeRules.microphoneEntry(for: recorder.translationMicrophonePermission, recordingAllowed: recordingAllowed())
        switch entry {
        case .setupRequired:
            translationMicrophoneSetup = nil
            accessSetupRequested = true
        case .startRecording:
            translationMicrophoneSetup = nil
            beginRecording(intentUptime: nil)
        case .explainPermission, .settingsRequired:
            translationMicrophoneSetup = entry
        }
    }

    func allowMicrophoneAndRecord() {
        guard translationMicrophoneSetup == .explainPermission, !session.isBusy else { return }
        guard recordingAllowed() else { requestTranslationHomeRecording(); return }
        if recorder.translationMicrophonePermission == .denied {
            translationMicrophoneSetup = .settingsRequired
            return
        }
        translationMicrophoneSetup = nil
        beginRecording(intentUptime: nil)
    }

    func refreshTranslationMicrophoneSetup() {
        if translationMicrophoneSetup == .settingsRequired, recorder.translationMicrophonePermission == .allowed {
            translationMicrophoneSetup = nil
            if case .failed = session.state { session.cancel() }
        }
    }

    func submitTranslationDraft(_ draft: String) {
        guard isMock, translationMicrophoneSetup == nil,
              let text = CaptureTranslationHomeRules.validatedText(draft),
              let identifier = session.beginTypedTranslation(language: language) else { return }
        let target = session.language
        recognizedText = nil
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let sample = try await self.processor.translate(text: text, to: target, sessionID: identifier)
                try Task.checkCancellation()
                self.session.complete(sample, for: identifier)
            } catch is CancellationError {
            } catch {
                self.session.fail("サンプルを表示できませんでした。もう一度試してください。", for: identifier)
            }
        }
    }
    #endif

    func startRecording() {
        beginRecording(intentUptime: nil)
    }

    private func beginRecording(intentUptime: TimeInterval?) {
        #if PHRABIT_OFFLINE_STARTUP_TIMING
        let handlingUptime = ProcessInfo.processInfo.systemUptime
        #endif
        guard recordingAllowed() else { accessSetupRequested = true; return }
        guard let identifier = session.begin(language: language) else { return }
        #if PHRABIT_OFFLINE_STARTUP_TIMING
        startupTiming = nil
        #endif
        recognizedText = nil
        uploadMayHaveStarted = false
        operationTask = Task { [weak self] in
            guard let self else { return }
            #if PHRABIT_OFFLINE_STARTUP_TIMING
            var timing = CaptureStartupTiming(intentUptime: intentUptime, handlingUptime: handlingUptime)
            #endif
            do {
                #if PHRABIT_OFFLINE_STARTUP_TIMING
                try await self.recorder.start(authorized: self.recordingAllowed, onStartup: { checkpoint in
                    timing.mark(checkpoint, at: ProcessInfo.processInfo.systemUptime)
                })
                #else
                try await self.recorder.start(authorized: self.recordingAllowed)
                #endif
                guard self.session.operationID == identifier else { return }
                self.recordingStartedAt = Date()
                self.session.recordingBegan(for: identifier)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                #if PHRABIT_OFFLINE_STARTUP_TIMING
                timing.mark(.readySignal, at: ProcessInfo.processInfo.systemUptime)
                self.startupTiming = timing
                #endif
                if !self.setupComplete {
                    self.setupComplete = true
                    UserDefaults.standard.set(true, forKey: Self.setupKey)
                }
            } catch is CancellationError {
            } catch {
                #if PHRABIT_OFFLINE_STARTUP_TIMING
                if self.session.operationID == identifier { self.startupTiming = timing }
                #endif
                #if PHRABIT_OFFLINE_TRANSLATION_HOME || PHRABIT_PREVIEW_TRANSLATION_HOME
                if self.session.operationID == identifier, self.recorder.translationMicrophonePermission == .denied {
                    self.translationMicrophoneSetup = .settingsRequired
                }
                #endif
                if !self.recordingAllowed() { self.accessSetupRequested = true }
                self.session.fail(error.localizedDescription, for: identifier)
            }
        }
    }

    func stopAndTranslate() {
        guard recordingAllowed() else { cancel(); accessSetupRequested = true; return }
        guard let identifier = session.beginRecognition() else { return }
        recordingStartedAt = nil
        let recordingURL: URL
        do {
            recordingURL = try recorder.stop()
        } catch {
            session.fail(error.localizedDescription, for: identifier)
            return
        }
        let targetLanguage = session.language
        let duration = recorder.completedDurationMilliseconds
        operationTask = Task { [weak self] in
            defer { try? FileManager.default.removeItem(at: recordingURL) }
            guard let self else { return }
            do {
                try Task.checkCancellation()
                let audio: Data
                if self.processor.sendsAudio {
                    audio = try Data(contentsOf: recordingURL)
                    try FileManager.default.removeItem(at: recordingURL)
                } else {
                    self.recorder.discard(recordingURL)
                    audio = Data()
                }
                try Task.checkCancellation()
                self.uploadMayHaveStarted = self.processor.sendsAudio
                let text = try await self.processor.transcribe(audio: audio, durationMilliseconds: duration, sessionID: identifier)
                try Task.checkCancellation()
                guard self.session.operationID == identifier else { return }
                guard self.recordingAllowed() else { throw CaptureClientError.unavailable }
                guard !text.isEmpty, text.utf16.count <= 500 else { throw CaptureClientError.invalidInput }
                self.recognizedText = text
                guard self.session.recognitionCompleted(for: identifier) else { return }
                let result = try await self.processor.translate(text: text, to: targetLanguage, sessionID: identifier)
                try Task.checkCancellation()
                guard self.recordingAllowed() else { self.cancel(); return }
                self.session.complete(result, for: identifier)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, self.session.operationID == identifier else { return }
                if let clientError = error as? CaptureClientError, case .authenticationRequired = clientError { self.authenticationRequired(); self.accessSetupRequested = true }
                self.session.fail((error as? CaptureClientError)?.localizedDescription ?? "処理を完了できませんでした。", for: identifier)
            }
        }
    }

    func cancel() {
        #if PHRABIT_OFFLINE_TRANSLATION_HOME || PHRABIT_PREVIEW_TRANSLATION_HOME
        translationMicrophoneSetup = nil
        #endif
        let cancelledIdentifier = session.isBusy && uploadMayHaveStarted ? session.operationID : nil
        operationTask?.cancel()
        operationTask = nil
        recorder.cancel()
        recordingStartedAt = nil
        if let identifier = cancelledIdentifier {
            session.fail("中止しました。送信済みの処理には料金が発生する場合があります。", for: identifier)
        } else {
            session.cancel()
        }
        recognizedText = nil
        uploadMayHaveStarted = false
    }

    func retryTranslation() {
        guard isMock, let text = recognizedText, let identifier = session.retryTranslation() else { return }
        let targetLanguage = session.language
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.processor.translate(text: text, to: targetLanguage, sessionID: identifier)
                try Task.checkCancellation()
                self.session.complete(result, for: identifier)
            } catch is CancellationError {
            } catch {
                if let clientError = error as? CaptureClientError, case .authenticationRequired = clientError { self.authenticationRequired(); self.accessSetupRequested = true }
                self.session.fail((error as? CaptureClientError)?.localizedDescription ?? "処理を完了できませんでした。", for: identifier)
            }
        }
    }

    func stopForBackground() {
        recognizedText = nil
        guard session.isBusy else { session.cancel(); return }
        recordingFailed(uploadMayHaveStarted
            ? "中止しました。送信済みの処理には料金が発生する場合があります。"
            : "画面を閉じたため中止しました。音声は送信していません。")
    }

    private func recordingFailed(_ message: String) {
        guard let identifier = session.operationID else { return }
        operationTask?.cancel()
        operationTask = nil
        recorder.cancel()
        recordingStartedAt = nil
        session.fail(message, for: identifier)
    }
}

