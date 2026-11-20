import XCTest
@testable import PhrabitCaptureCore

final class CaptureStartupTimingTests: XCTestCase {
    func testFullControlLaunchBreakdown() {
        var timing = CaptureStartupTiming(intentUptime: 100, handlingUptime: 100.60)
        timing.mark(.permissionResolved, at: 100.63)
        timing.mark(.audioSessionActive, at: 100.82)
        timing.mark(.recorderPrepared, at: 101.00)
        timing.mark(.recorderStarted, at: 101.02)
        timing.mark(.readySignal, at: 101.07)
        XCTAssertEqual(timing.milliseconds(for: .intentToActive), 600)
        XCTAssertEqual(timing.milliseconds(for: .activeToPermission), 30)
        XCTAssertEqual(timing.milliseconds(for: .audioSession), 190)
        XCTAssertEqual(timing.milliseconds(for: .recorderPreparation), 180)
        XCTAssertEqual(timing.milliseconds(for: .recordCall), 20)
        XCTAssertEqual(timing.milliseconds(for: .readySignal), 50)
        XCTAssertEqual(timing.milliseconds(for: .activeToReady), 470)
        XCTAssertEqual(timing.milliseconds(for: .intentToReady), 1_070)
    }

    func testDirectOrStaleRequestDoesNotInventLockScreenTiming() {
        let direct = CaptureStartupTiming(intentUptime: nil, handlingUptime: 80)
        let stale = CaptureStartupTiming(intentUptime: 40, handlingUptime: 80)
        let future = CaptureStartupTiming(intentUptime: 81, handlingUptime: 80)
        for timing in [direct, stale, future] {
            XCTAssertNil(timing.milliseconds(for: .intentToActive))
            XCTAssertNil(timing.milliseconds(for: .intentToReady))
        }
    }

    func testFailedInterruptedOrOutOfOrderMarkersDoNotReportReady() {
        var timing = CaptureStartupTiming(intentUptime: nil, handlingUptime: 40)
        timing.mark(.recorderStarted, at: 40.05)
        timing.mark(.permissionResolved, at: 39.98)
        timing.mark(.permissionResolved, at: 40.10)
        timing.mark(.permissionResolved, at: 40.30)
        timing.mark(.audioSessionActive, at: .infinity)
        timing.mark(.readySignal, at: 41)
        XCTAssertEqual(timing.milliseconds(for: .activeToPermission), 100)
        XCTAssertNil(timing.milliseconds(for: .audioSession))
        XCTAssertNil(timing.milliseconds(for: .recordCall))
        XCTAssertNil(timing.milliseconds(for: .activeToReady))
    }
}
