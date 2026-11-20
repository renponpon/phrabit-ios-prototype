import Foundation

public struct CaptureStartupTiming {
    public enum Checkpoint: Int, CaseIterable {
        case permissionResolved
        case audioSessionActive
        case recorderPrepared
        case recorderStarted
        case readySignal
    }

    public enum Segment: String, CaseIterable {
        case intentToActive
        case activeToPermission
        case audioSession
        case recorderPreparation
        case recordCall
        case readySignal
        case activeToReady
        case intentToReady
    }

    public let intentUptime: TimeInterval?
    public let handlingUptime: TimeInterval
    private var markers: [Checkpoint: TimeInterval] = [:]

    public init(intentUptime: TimeInterval?, handlingUptime: TimeInterval) {
        self.handlingUptime = handlingUptime
        if let intentUptime, intentUptime.isFinite, intentUptime >= 0,
           (0...30).contains(handlingUptime - intentUptime) {
            self.intentUptime = intentUptime
        } else {
            self.intentUptime = nil
        }
    }

    public mutating func mark(_ checkpoint: Checkpoint, at uptime: TimeInterval) {
        let previous = Checkpoint(rawValue: checkpoint.rawValue - 1)
        let start: TimeInterval?
        if let previous {
            start = markers[previous]
        } else {
            start = handlingUptime
        }
        guard markers[checkpoint] == nil,
              milliseconds(from: start, to: uptime) != nil else { return }
        markers[checkpoint] = uptime
    }

    public func milliseconds(for segment: Segment) -> Int? {
        switch segment {
        case .intentToActive:
            return milliseconds(from: intentUptime, to: handlingUptime)
        case .activeToPermission:
            return milliseconds(from: handlingUptime, to: markers[.permissionResolved])
        case .audioSession:
            return milliseconds(from: markers[.permissionResolved], to: markers[.audioSessionActive])
        case .recorderPreparation:
            return milliseconds(from: markers[.audioSessionActive], to: markers[.recorderPrepared])
        case .recordCall:
            return milliseconds(from: markers[.recorderPrepared], to: markers[.recorderStarted])
        case .readySignal:
            return milliseconds(from: markers[.recorderStarted], to: markers[.readySignal])
        case .activeToReady:
            return milliseconds(from: handlingUptime, to: markers[.readySignal])
        case .intentToReady:
            return milliseconds(from: intentUptime, to: markers[.readySignal])
        }
    }

    private func milliseconds(from start: TimeInterval?, to end: TimeInterval?) -> Int? {
        guard let start, let end, start >= 0, start.isFinite, end.isFinite else { return nil }
        let elapsed = end - start
        guard (0...300).contains(elapsed) else { return nil }
        return Int((elapsed * 1_000).rounded())
    }
}
