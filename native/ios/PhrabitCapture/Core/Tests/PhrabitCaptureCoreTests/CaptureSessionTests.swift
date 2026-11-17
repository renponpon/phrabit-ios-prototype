import XCTest
@testable import PhrabitCaptureCore

final class CaptureSessionTests: XCTestCase {
    func testRecordingToTranslationToResult() throws {
        var session = CaptureSession()
        let identifier = try XCTUnwrap(session.begin(language: .chinese))
        XCTAssertEqual(session.state, .preparing)
        session.recordingBegan(for: identifier)
        XCTAssertEqual(session.state, .recording)
        XCTAssertEqual(session.beginTranslation(), identifier)
        let translation = MockTranslator.sample(for: .chinese)
        session.complete(translation, for: identifier)
        XCTAssertEqual(session.state, .result(translation))
        XCTAssertNil(session.operationID)
        XCTAssertFalse(session.isBusy)
    }

    func testRepeatedStartDoesNotReplaceAnActiveRecording() throws {
        var session = CaptureSession()
        let identifier = try XCTUnwrap(session.begin(language: .english))
        XCTAssertNil(session.begin(language: .chinese))
        session.recordingBegan(for: identifier)
        XCTAssertNil(session.begin(language: .chinese))
        XCTAssertEqual(session.language, .english)
        XCTAssertEqual(session.operationID, identifier)
    }

    func testRepeatedStopDoesNotTranslateTwice() throws {
        var session = CaptureSession()
        let identifier = try XCTUnwrap(session.begin(language: .english))
        XCTAssertNil(session.beginTranslation())
        session.recordingBegan(for: identifier)
        XCTAssertEqual(session.beginTranslation(), identifier)
        XCTAssertNil(session.beginTranslation())
        XCTAssertNil(session.begin(language: .chinese))
    }

    func testCancelledOperationCannotRestoreAResult() throws {
        var session = CaptureSession()
        let identifier = try XCTUnwrap(session.begin(language: .chinese))
        session.recordingBegan(for: identifier)
        _ = session.beginTranslation()
        session.cancel()
        session.complete(MockTranslator.sample(for: .chinese), for: identifier)
        session.fail("古いエラー", for: identifier)
        XCTAssertEqual(session.state, .idle)
        XCTAssertNil(session.operationID)
    }

    func testOldPermissionResultCannotStartANewSession() throws {
        var session = CaptureSession()
        let oldIdentifier = try XCTUnwrap(session.begin(language: .chinese))
        session.cancel()
        let currentIdentifier = try XCTUnwrap(session.begin(language: .english))
        session.recordingBegan(for: oldIdentifier)
        session.fail("古い権限エラー", for: oldIdentifier)
        XCTAssertEqual(session.state, .preparing)
        XCTAssertEqual(session.operationID, currentIdentifier)
    }

    func testFailureCanBeRetried() throws {
        var session = CaptureSession()
        let identifier = try XCTUnwrap(session.begin(language: .english))
        session.fail("マイクが使えません", for: identifier)
        XCTAssertEqual(session.state, .failed("マイクが使えません"))
        XCTAssertNotNil(session.begin(language: .english))
    }

    func testResultFromDifferentLanguageIsRejected() throws {
        var session = CaptureSession()
        let identifier = try XCTUnwrap(session.begin(language: .english))
        session.recordingBegan(for: identifier)
        _ = session.beginTranslation()
        session.complete(MockTranslator.sample(for: .chinese), for: identifier)
        XCTAssertEqual(session.state, .translating)
    }

    func testEnglishAndChineseSamplesAreExplicitlySeparate() {
        let english = MockTranslator.sample(for: .english)
        let chinese = MockTranslator.sample(for: .chinese)
        XCTAssertEqual(english.sourceText, chinese.sourceText)
        XCTAssertNil(english.reading)
        XCTAssertFalse(chinese.reading?.isEmpty ?? true)
        XCTAssertEqual(english.language, .english)
        XCTAssertEqual(chinese.language, .chinese)
        XCTAssertEqual(CaptureSession.maximumRecordingDuration, 20)
    }

    func testCancelledMockRequestDoesNotProduceAResult() async {
        let task = Task { try await MockTranslator().translate(to: .chinese) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("キャンセルした模擬翻訳が完了しました")
        } catch is CancellationError {
        } catch {
            XCTFail("予期しないエラーです: \(error)")
        }
    }

    func testRecognitionAndRetryIgnoreStaleResults() throws {
        var session = CaptureSession()
        let identifier = try XCTUnwrap(session.begin(language: .chinese))
        session.recordingBegan(for: identifier)
        XCTAssertEqual(session.beginRecognition(), identifier)
        XCTAssertTrue(session.isBusy)
        XCTAssertNil(session.beginRecognition())
        XCTAssertFalse(session.recognitionCompleted(for: UUID()))
        XCTAssertTrue(session.recognitionCompleted(for: identifier))
        session.fail("翻訳失敗", for: identifier)
        let retryID = try XCTUnwrap(session.retryTranslation())
        session.complete(MockTranslator.sample(for: .chinese), for: identifier)
        XCTAssertEqual(session.state, .translating)
        session.complete(MockTranslator.sample(for: .chinese), for: retryID)
        XCTAssertFalse(session.isBusy)
        XCTAssertNil(session.retryTranslation())
    }
}

