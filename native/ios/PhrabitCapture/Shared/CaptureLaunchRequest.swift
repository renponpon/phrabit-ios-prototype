import Foundation

enum CaptureLaunchRequest {
    static let notification = Notification.Name("phrabit.quickcapture.launch")
    private static let key = "phrabit.quickcapture.pending-launch"

    @MainActor
    static func enqueue() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
        NotificationCenter.default.post(name: notification, object: nil)
    }

    @MainActor
    static func consume() -> Bool {
        let defaults = UserDefaults.standard
        let timestamp = defaults.object(forKey: key) as? TimeInterval
        defaults.removeObject(forKey: key)
        guard let timestamp else { return false }
        let age = Date().timeIntervalSince1970 - timestamp
        return (0...30).contains(age)
    }
}

