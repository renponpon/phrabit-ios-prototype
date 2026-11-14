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
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey) }
    }

    private static let languageKey = "phrabit.quickcapture.language"
    private static let setupKey = "phrabit.quickcapture.setup"
    private let recorder = AudioRecorder()
    private let translator = MockTranslator()
    private var operationTask: Task<Void, Never>?

    init() {
        language = CaptureLanguage(rawValue: UserDefaults.standard.string(forKey: Self.languageKey) ?? "") ?? .chinese
        setupComplete = UserDefaults.standard.bool(forKey: Self.setupKey)
        recorder.onTimeLimit = { [weak self] in self?.stopAndTranslate() }
        recorder.onInterruption = { [weak self] in
            self?.recordingFailed("通話などで録音が中断されました。もう一度話してください。")
        }
        recorder.onFailure = { [weak self] in
            self?.recordingFailed("録音を完了できませんでした。もう一度試してください。")
        }
    }

    func handlePendingLaunch() {
        guard CaptureLaunchRequest.consume(), !session.isBusy else { return }
        if setupComplete {
            startRecording()
        }
    }

    func startRecording() {
        guard let identifier = session.begin(language: language) else { return }
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.recorder.start()
                guard self.session.operationID == identifier else { return }
                self.setupComplete = true
                UserDefaults.standard.set(true, forKey: Self.setupKey)
                self.recordingStartedAt = Date()
                self.session.recordingBegan(for: identifier)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } catch is CancellationError {
            } catch {
                self.session.fail(error.localizedDescription, for: identifier)
            }
        }
    }

    func stopAndTranslate() {
        guard let identifier = session.beginTranslation() else { return }
        recordingStartedAt = nil
        let recordingURL: URL
        do {
            recordingURL = try recorder.stop()
        } catch {
            session.fail(error.localizedDescription, for: identifier)
            return
        }
        let targetLanguage = session.language
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.recorder.discard(recordingURL) }
            do {
                let result = try await self.translator.translate(to: targetLanguage)
                self.session.complete(result, for: identifier)
            } catch is CancellationError {
            } catch {
                self.session.fail(error.localizedDescription, for: identifier)
            }
        }
    }

    func cancel() {
        operationTask?.cancel()
        operationTask = nil
        recorder.cancel()
        recordingStartedAt = nil
        session.cancel()
    }

    func stopForBackground() {
        guard session.isBusy else { return }
        recordingFailed("画面を閉じたため中止しました。音声は送信していません。")
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

