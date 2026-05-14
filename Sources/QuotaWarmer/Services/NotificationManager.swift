import Foundation
import UserNotifications

@MainActor
class NotificationManager {
    static let shared = NotificationManager()

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func scheduleWindowWarning(for tool: ToolID, expiresAt: Date) {
        let warnDate = expiresAt.addingTimeInterval(-1800)
        guard warnDate > Date() else { return }

        cancelPending(id: warningID(tool))

        let content = UNMutableNotificationContent()
        content.title = "\(tool.displayName) — Window Expiring Soon"
        content.body  = "30 minutes left in your 5h quota window. QuotaWarmer will auto-trigger at reset."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: warnDate.timeIntervalSinceNow,
            repeats: false
        )
        let req = UNNotificationRequest(identifier: warningID(tool), content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(req)
    }

    func notifyActivated(tool: ToolID) {
        let content = UNMutableNotificationContent()
        content.title = "\(tool.displayName) — Window Started"
        content.body  = "5-hour quota window is now active. Next auto-trigger in 5 hours."
        content.sound = .default

        let req = UNNotificationRequest(
            identifier: "activated.\(tool.rawValue).\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }

    func cancelAll(for tool: ToolID) {
        cancelPending(id: warningID(tool))
    }

    private func warningID(_ tool: ToolID) -> String { "warning.\(tool.rawValue)" }

    private func cancelPending(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}
