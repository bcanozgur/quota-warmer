import Foundation

struct DayActivity {
    let date: Date
    let sessionCount: Int
}

class ActivityScanner {

    private let iso8601Frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Public

    /// Last message time across all logs (display only).
    func lastActivity(for tool: ToolID) -> Date? {
        guard let base = tool.logDirectoryURL,
              FileManager.default.fileExists(atPath: base.path) else { return nil }
        var latest: Date?
        enumerateJSONL(in: base) { url in
            if let t = self.lastTimestamp(in: url) {
                if latest == nil || t > latest! { latest = t }
            }
        }
        return latest
    }

    /// FIRST message timestamp in the current 5-hour window.
    /// This is the correct anchor: window expires at windowStart + 5h.
    /// Returns nil if no activity within the last windowDuration seconds.
    func windowStartTime(for tool: ToolID) -> Date? {
        guard let base = tool.logDirectoryURL,
              FileManager.default.fileExists(atPath: base.path) else { return nil }

        let cutoff = Date().addingTimeInterval(-tool.windowDuration)

        // Collect files that were touched within the current window
        var candidates: [(mtime: Date, url: URL)] = []
        enumerateJSONL(in: base) { url in
            if let mtime = self.mtime(of: url), mtime >= cutoff {
                candidates.append((mtime, url))
            }
        }

        guard !candidates.isEmpty else { return nil }
        // Sort oldest-first so we scan earliest sessions first
        candidates.sort { $0.mtime < $1.mtime }

        var windowStart: Date?
        for candidate in candidates {
            if let ts = firstTimestampInWindow(candidate.url, cutoff: cutoff) {
                if windowStart == nil || ts < windowStart! { windowStart = ts }
            }
        }
        return windowStart
    }

    func weeklyActivity(for tool: ToolID) -> [DayActivity] {
        guard let base = tool.logDirectoryURL,
              FileManager.default.fileExists(atPath: base.path) else { return emptyWeek() }

        let calendar = Calendar.current
        let now      = Date()
        let cutoff   = calendar.date(byAdding: .day, value: -7, to: now) ?? .distantPast

        var countsByDay: [Date: Int] = [:]
        for offset in 0..<7 {
            if let d = calendar.date(byAdding: .day, value: -offset, to: now) {
                countsByDay[calendar.startOfDay(for: d)] = 0
            }
        }

        enumerateJSONL(in: base) { url in
            guard let ts = self.lastTimestamp(in: url), ts >= cutoff else { return }
            let day = calendar.startOfDay(for: ts)
            if countsByDay[day] != nil { countsByDay[day]! += 1 }
        }

        return countsByDay
            .sorted { $0.key < $1.key }
            .map { DayActivity(date: $0.key, sessionCount: $0.value) }
    }

    // MARK: - Private helpers

    /// Reads first ~4 KB and returns the earliest timestamp >= cutoff.
    private func firstTimestampInWindow(_ url: URL, cutoff: Date) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 4096)
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: "\n") {
            if let ts = parseTimestamp(from: line), ts >= cutoff { return ts }
        }
        return nil
    }

    /// Reads last ~4 KB and returns the most recent timestamp.
    private func lastTimestamp(in url: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        guard fileSize > 0 else { return nil }
        let readSize = UInt64(min(fileSize, 4096))
        try? handle.seek(toOffset: fileSize - readSize)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: "\n").reversed() {
            if let ts = parseTimestamp(from: line) { return ts }
        }
        return nil
    }

    private func mtime(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func parseTimestamp(from jsonLine: String) -> Date? {
        let t = jsonLine.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty,
              let data = t.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ts   = obj["timestamp"] as? String else { return nil }
        return iso8601Frac.date(from: ts) ?? iso8601.date(from: ts)
    }

    private func enumerateJSONL(in directory: URL, handler: (URL) -> Void) {
        guard let en = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var count = 0
        for case let url as URL in en {
            count += 1; if count > 50_000 { break }
            guard url.pathExtension == "jsonl" else { continue }
            handler(url)
        }
    }

    private func emptyWeek() -> [DayActivity] {
        let calendar = Calendar.current
        let now      = Date()
        return (0..<7).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: now).map {
                DayActivity(date: calendar.startOfDay(for: $0), sessionCount: 0)
            }
        }
    }
}
