import AVFAudio
import Foundation
import PhrabitCaptureCore

@MainActor
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    enum RecordingError: LocalizedError {
        case permissionDenied
        case unavailable
        case missingRecording

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "マイクが許可されていません。iPhoneの設定でPhrabit試作のマイクを許可してください。"
            case .unavailable:
                return "録音を開始できませんでした。通話などが終わってから、もう一度試してください。"
            case .missingRecording:
                return "録音が空でした。もう一度話してください。"
            }
        }
    }

    var onTimeLimit: (() -> Void)?
    var onInterruption: (() -> Void)?
    var onFailure: (() -> Void)?
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var startedAtUptime: TimeInterval?
    private(set) var completedDurationMilliseconds = 0
    private var interruptionObserver: NSObjectProtocol?

    override init() {
        super.init()
        if let abandonedFiles = try? FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: nil
        ) {
            for file in abandonedFiles where file.lastPathComponent.hasPrefix("phrabit-") && file.pathExtension == "m4a" {
                try? FileManager.default.removeItem(at: file)
            }
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: rawValue) == .began else { return }
            Task { @MainActor [weak self] in
                guard let self, self.recorder != nil else { return }
                self.onInterruption?()
            }
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    func start() async throws {
        let permitted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        try Task.checkCancellation()
        guard permitted else { throw RecordingError.permissionDenied }

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .default, options: [])
        try audioSession.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try audioSession.setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("phrabit-\(UUID().uuidString).m4a")
        recordingURL = url

        do {
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.protectionKey: FileProtectionType.complete]
            ) else { throw RecordingError.unavailable }
            let audioRecorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ])
            recorder = audioRecorder
            audioRecorder.delegate = self
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            guard audioRecorder.prepareToRecord(),
                  audioRecorder.record(forDuration: CaptureSession.maximumRecordingDuration) else {
                throw RecordingError.unavailable
            }
            startedAtUptime = ProcessInfo.processInfo.systemUptime
        } catch {
            cancel()
            throw error
        }
    }

    func stop() throws -> URL {
        guard let audioRecorder = recorder, let url = recordingURL else {
            throw RecordingError.missingRecording
        }
        let elapsed = startedAtUptime.map { max(0, ProcessInfo.processInfo.systemUptime - $0) } ?? 0
        let duration = max(audioRecorder.currentTime, elapsed)
        completedDurationMilliseconds = Int(min(21.5, duration) * 1000)
        audioRecorder.delegate = nil
        audioRecorder.stop()
        recorder = nil
        recordingURL = nil
        startedAtUptime = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard duration >= 0.25, fileSize > 0 else {
            discard(url)
            throw RecordingError.missingRecording
        }
        return url
    }

    func cancel() {
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        startedAtUptime = nil
        if let recordingURL {
            discard(recordingURL)
        }
        recordingURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated func audioRecorderDidFinishRecording(_ finishedRecorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === finishedRecorder else { return }
            if flag {
                self.onTimeLimit?()
            } else {
                self.onFailure?()
            }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ failedRecorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === failedRecorder else { return }
            self.onFailure?()
        }
    }
}

