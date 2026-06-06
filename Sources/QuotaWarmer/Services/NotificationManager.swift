import Foundation
import AppKit
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

    func notifyWarmupCommandSent(tool: ToolID) {
        let content = UNMutableNotificationContent()
        content.title = "\(tool.displayName) 5h Window Warmup Sent"
        content.subtitle = "QuotaWarmer"
        content.body = "QuotaWarmer sent the warmup command for \(tool.displayName). The next quota refresh will confirm the active 5-hour window."
        content.sound = .default
        if let attachment = brandedAttachment(for: tool) {
            content.attachments = [attachment]
        }

        let req = UNNotificationRequest(
            identifier: "warmupSent.\(tool.rawValue).\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
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

    func notifyMorningCatchUp(onBattery: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "Morning Pre-warm — Caught Up"
        content.body  = onBattery
            ? "The scheduled wake was skipped (on battery). Your quota window is being warmed now that the Mac is awake."
            : "Your quota window is being warmed now that the Mac is awake."
        content.sound = .default

        let req = UNNotificationRequest(
            identifier: "morningCatchUp.\(Int(Date().timeIntervalSince1970))",
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

    private func brandedAttachment(for tool: ToolID) -> UNNotificationAttachment? {
        guard let data = brandedAttachmentImageData(for: tool) else { return nil }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaWarmerNotifications", isDirectory: true)
        let fileURL = directory.appendingPathComponent("warmup-\(tool.rawValue).png")

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            return try UNNotificationAttachment(identifier: "warmup.\(tool.rawValue).branding", url: fileURL)
        } catch {
            return nil
        }
    }

    private func brandedAttachmentImageData(for tool: ToolID) -> Data? {
        guard let providerIcon = NSImage(named: tool.notificationAssetName) else { return nil }

        let size = NSSize(width: 256, height: 128)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        NSApp.applicationIconImage.draw(
            in: NSRect(x: 24, y: 22, width: 84, height: 84),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        drawIcon(
            providerIcon,
            in: NSRect(x: 148, y: 26, width: 76, height: 76),
            tint: tool.notificationTint
        )

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func drawIcon(_ image: NSImage, in rect: NSRect, tint: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        tint.setFill()
        rect.fill(using: .sourceIn)
        NSGraphicsContext.restoreGraphicsState()
    }
}

private extension ToolID {
    var notificationAssetName: String {
        switch self {
        case .claude: return "ClaudeCode"
        case .codex: return "Codex"
        }
    }

    var notificationTint: NSColor {
        switch self {
        case .claude: return .systemOrange
        case .codex: return .systemPurple
        }
    }
}
