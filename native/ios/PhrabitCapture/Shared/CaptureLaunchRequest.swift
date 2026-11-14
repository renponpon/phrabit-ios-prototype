import Foundation

enum CaptureLaunchRequest {
    static let notification = Notification.Name("phrabit.quickcapture.launch")
    private static let key = "phrabit.quickcapture.pending-launch"

    @MainActor
    static func enqueue() {
        UserDefaults.standard.set(UUID().uuidString, forKey: key)
        NotificationCenter.default.post(name: notification, object: nil)
    }

    @MainActor
    static func consume() -> Bool {
        guard UserDefaults.standard.string(forKey: key) != nil else { return false }
        UserDefaults.standard.removeObject(forKey: key)
        return true
    }
}

