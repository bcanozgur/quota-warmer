import Foundation

/// Builds the plain-text diagnostics bundle behind Settings → "Export
/// Diagnostics…" and the "Report an Issue" URL. Contains no tokens, auth
/// headers or raw warm-up output; text is run through the logger's redaction.
enum DiagnosticsExport {
    static let issuesURL = "https://github.com/bcanozgur/quota-warmer/issues/new"

    /// Global, non-secret settings that are safe to include in a bug report.
    static let settingKeys = [
        "refreshInterval", "morningPrewarmEnabled", "morningPrewarmHour", "rateLimitGuard",
        "debugLevel", "launchAtLogin", "globalPassive", "notifyWarning", "notifyActivated"
    ]

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    static var macOSVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }

    /// Only app + macOS version — never user data — go into the URL.
    static func issueURL(appVersion: String = appVersion, macOS: String = macOSVersion) -> URL? {
        var components = URLComponents(string: issuesURL)
        components?.queryItems = [
            URLQueryItem(name: "body", value: "**QuotaWarmer:** \(appVersion)\n**macOS:** \(macOS)\n\n<!-- Describe the problem. Attach an exported diagnostics file only if you are comfortable sharing it. -->")
        ]
        return components?.url
    }

    /// `providers` are `(storageKey, "mode · pinned/unpinned")` summaries.
    static func report(
        events: [HistoryEvent], providers: [(String, String)], now: Date = Date(),
        logFiles: [URL] = DiagnosticLogger.logFiles, defaults: UserDefaults = .standard
    ) -> String {
        let iso = ISO8601DateFormatter()
        var out: [String] = []
        out.append("QuotaWarmer diagnostics")
        out.append("Generated: \(iso.string(from: now))")
        out.append("App version: \(appVersion)")
        out.append("macOS: \(macOSVersion)")
        out.append("")
        out.append("== Settings ==")
        for key in settingKeys {
            if let value = defaults.object(forKey: key) { out.append("\(key) = \(value)") }
        }
        for (key, summary) in providers { out.append("provider \(key): \(summary)") }
        out.append("")
        out.append("== Last \(events.count) events (oldest first) ==")
        for event in events {
            var line = "\(iso.string(from: event.timestamp)) \(event.tool?.storageKey ?? "app") \(event.kind.rawValue)"
            if let outcome = event.outcome { line += " outcome=\(outcome.rawValue)" }
            if let model = event.model { line += " model=\(model)" }
            if let reset = event.windowResetAt { line += " resetAt=\(iso.string(from: reset))" }
            line += " | \(event.title) | \(event.detail)"
            out.append(line)
        }
        for url in logFiles.reversed() {
            out.append("")
            out.append("== \(url.lastPathComponent) ==")
            if let text = try? String(contentsOf: url, encoding: .utf8) { out.append(text.trimmingCharacters(in: .newlines)) }
        }
        let text = out.joined(separator: "\n") + "\n"
        // Redact secrets and the user's home path (it contains their account name).
        return DiagnosticLogger.redacted(text).replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
