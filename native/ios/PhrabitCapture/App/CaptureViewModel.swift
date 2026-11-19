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
            if self.isMock {
                self.stopAndTranslate()
            } else {
                self.recordingFailed("20秒に達したため録音を破棄しました。音声は送信していません。")
            }
        }
        recorder.onInterruption = { [weak self] in
            self?.recordingFailed("通話などで録音が中断されました。もう一度話してください。")
        }
        recorder.onFailure = { [weak self] in
            self?.recordingFailed("録音を完了できませんでした。もう一度試してください。")
        }
    }

    func handlePendingLaunch() {
        guard CaptureLaunchRequest.consume(), !session.isBusy else { return }
        guard recordingAllowed() else { accessSetupRequested = true; return }
        if setupComplete {
            startRecording()
        }
    }

    func startRecording() {
        guard recordingAllowed() else { accessSetupRequested = true; return }
        guard let identifier = session.begin(language: language) else { return }
        recognizedText = nil
        uploadMayHaveStarted = false
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.recorder.start(authorized: self.recordingAllowed)
                guard self.session.operationID == identifier else { return }
                self.recordingStartedAt = Date()
                self.session.recordingBegan(for: identifier)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if !self.setupComplete {
                    self.setupComplete = true
                    UserDefaults.standard.set(true, forKey: Self.setupKey)
                }
            } catch is CancellationError {
            } catch {
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
                guard !text.isEmpty, text.utf16.count <= 500 else { throw CaptureClientError.invalidInput }
                self.recognizedText = text
                guard self.session.recognitionCompleted(for: identifier) else { return }
                let result = try await self.processor.translate(text: text, to: targetLanguage, sessionID: identifier)
                try Task.checkCancellation()
                guard self.recordingAllowed() else { self.cancel(); return }
                self.session.complete(result, for: identifier)
            } catch is CancellationError {
            } catch {
                if let clientError = error as? CaptureClientError, case .authenticationRequired = clientError { self.authenticationRequired(); self.accessSetupRequested = true }
                self.session.fail((error as? CaptureClientError)?.localizedDescription ?? "処理を完了できませんでした。", for: identifier)
            }
        }
    }

    func cancel() {
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

