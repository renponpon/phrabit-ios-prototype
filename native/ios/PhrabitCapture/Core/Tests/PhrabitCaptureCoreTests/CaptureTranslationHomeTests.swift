import XCTest
@testable import PhrabitCaptureCore

final class CaptureTranslationHomeTests: XCTestCase {
    func testPermissionRoutesForFirstUseDeniedAndAllowed() {
        XCTAssertEqual(CaptureTranslationHomeRules.microphoneEntry(for: .notRequested), .explainPermission)
        XCTAssertEqual(CaptureTranslationHomeRules.microphoneEntry(for: .denied), .settingsRequired)
        XCTAssertEqual(CaptureTranslationHomeRules.microphoneEntry(for: .allowed), .startRecording)
    }

    func testTypedInputRejectsEmptyOrOverLimitWithoutChangingContent() {
        XCTAssertNil(CaptureTranslationHomeRules.validatedText(" \n "))
        XCTAssertEqual(CaptureTranslationHomeRules.validatedText(" こんにちは\n"), "こんにちは")
        let atLimit = String(repeating: "駅", count: CaptureTranslationHomeRules.inputLimit)
        XCTAssertEqual(CaptureTranslationHomeRules.validatedText(atLimit), atLimit)
        XCTAssertNil(CaptureTranslationHomeRules.validatedText(atLimit + "駅"))
        XCTAssertNil(CaptureTranslationHomeRules.validatedText(String(repeating: "😀", count: 251)))
    }

    func testTypedTranslationDoesNotEnterRecordingAndCannotOverlapVoice() throws {
        var session = CaptureSession()
        let typed = try XCTUnwrap(session.beginTypedTranslation(language: .english))
        XCTAssertEqual(session.state, .translating)
        XCTAssertNil(session.begin(language: .chinese))
        XCTAssertNil(session.beginRecognition())
        XCTAssertNil(session.beginTypedTranslation(language: .chinese))
        let english = MockTranslator.sample(for: .english)
        session.complete(english, for: typed)
        XCTAssertEqual(session.state, .result(english))
        let recorded = try XCTUnwrap(session.begin(language: .chinese))
        session.recordingBegan(for: recorded)
        XCTAssertNil(session.beginTypedTranslation(language: .english))
    }

    func testCancelledTypedTranslationCannotOverwriteANewRecording() throws {
        var session = CaptureSession()
        let typed = try XCTUnwrap(session.beginTypedTranslation(language: .chinese))
        session.cancel()
        let voice = try XCTUnwrap(session.begin(language: .chinese))
        session.complete(MockTranslator.sample(for: .chinese), for: typed)
        XCTAssertEqual(session.state, .preparing)
        XCTAssertEqual(session.operationID, voice)
    }
}
