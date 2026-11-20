import Foundation

enum CaptureLaunchRequest {
    static let notification = Notification.Name("phrabit.quickcapture.launch")
    private static let key = "phrabit.quickcapture.pending-launch"
    #if PHRABIT_OFFLINE_STARTUP_TIMING
    private static let timingKey = "phrabit.quickcapture.offline-timing.pending-launch"
    #endif

    @MainActor
    static func enqueue() {
        #if PHRABIT_OFFLINE_STARTUP_TIMING
        UserDefaults.standard.set(ProcessInfo.processInfo.systemUptime, forKey: timingKey)
        #endif
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
        NotificationCenter.default.post(name: notification, object: nil)
    }

    @MainActor
    static func consume(onIntentUptime: (TimeInterval) -> Void = { _ in }) -> Bool {
        let defaults = UserDefaults.standard
        let timestamp = defaults.object(forKey: key) as? TimeInterval
        defaults.removeObject(forKey: key)
        #if PHRABIT_OFFLINE_STARTUP_TIMING
        let uptime = defaults.object(forKey: timingKey) as? TimeInterval
        defaults.removeObject(forKey: timingKey)
        #endif
        guard let timestamp else { return false }
        let age = Date().timeIntervalSince1970 - timestamp
        guard (0...30).contains(age) else { return false }
        #if PHRABIT_OFFLINE_STARTUP_TIMING
        if let uptime { onIntentUptime(uptime) }
        #endif
        return true
    }
}

