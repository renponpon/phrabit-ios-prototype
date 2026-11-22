import Foundation
import XCTest
@testable import PhrabitCaptureCore

final class GuestCaptureFlowTests: XCTestCase {
    private let reset = Date(timeIntervalSince1970: 1_800_000_000)

    func testConsentAlwaysPrecedesRecording() {
        let permissions: [CaptureTranslationHomeRules.MicrophonePermission] = [.notRequested, .denied, .allowed]
        for permission in permissions {
            XCTAssertEqual(GuestCaptureEntry(consent: false, permission: permission), .consent)
        }
        XCTAssertEqual(GuestCaptureEntry(consent: true, permission: .notRequested), .microphone)
        XCTAssertEqual(GuestCaptureEntry(consent: true, permission: .denied), .microphoneSettings)
        XCTAssertEqual(GuestCaptureEntry(consent: true, permission: .allowed), .record)
    }

    func testQuotaFollowsSuppliedResponseAndCannotFallBelowZero() throws {
        var fixture = GuestCaptureFixture(response: GuestQuotaSnapshot(remaining: 1, nextReset: reset))
        try fixture.attempt(UUID())
        XCTAssertEqual(fixture.quota, GuestQuotaSnapshot(remaining: 0, nextReset: reset))
        XCTAssertThrowsError(try fixture.attempt(UUID())) { XCTAssertEqual($0 as? GuestCaptureFeedback, .daily) }
        XCTAssertEqual(fixture.quota.remaining, 0)
        XCTAssertEqual(GuestQuotaSnapshot(remaining: -1, nextReset: reset).remaining, 0)
    }

    func testPreDispatchFailuresDoNotConsumeQuota() {
        let choices: [GuestCaptureFeedback] = [.daily, .serviceBudget, .offline, .deviceCheck, .burst]
        for choice in choices {
            var fixture = GuestCaptureFixture(response: GuestQuotaSnapshot(remaining: 2, nextReset: reset), issue: choice)
            XCTAssertThrowsError(try fixture.attempt(UUID())) { XCTAssertEqual($0 as? GuestCaptureFeedback, choice) }
            XCTAssertEqual(fixture.quota.remaining, 2)
        }
    }

    func testPostDispatchFailureConsumesQuotaOnce() {
        let requestID = UUID()
        var fixture = GuestCaptureFixture(response: GuestQuotaSnapshot(remaining: 2, nextReset: reset), issue: .provider)
        XCTAssertThrowsError(try fixture.attempt(requestID)) { XCTAssertEqual($0 as? GuestCaptureFeedback, .provider) }
        XCTAssertThrowsError(try fixture.attempt(requestID)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(fixture.quota.remaining, 1)
    }
}
