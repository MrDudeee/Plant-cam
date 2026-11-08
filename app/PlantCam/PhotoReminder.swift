import Foundation
import UserNotifications

/// The daily "take your plant photos" reminder.
enum PhotoReminder {
    static let identifier = "plantcam.daily"

    /// Turns the reminder on or off. Returns false if iOS notifications aren't allowed.
    static func apply(enabled: Bool, minutes: Int) async -> Bool {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        guard enabled else { return true }

        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return false }

        let content = UNMutableNotificationContent()
        content.title = "Plant photos"
        content.body = "Time for today\u{2019}s side and overhead shots."
        content.sound = .default

        var parts = DateComponents()
        parts.hour = minutes / 60
        parts.minute = minutes % 60
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: true)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }
}
