import Foundation

/// One successful quota reading, as kept for the History tab. Field names are
/// short because a year of 5-minute samples is ~100K lines per account.
struct QuotaSample: Codable, Equatable {
    /// When the snapshot was fetched.
    let t: Date
    /// 5-hour window used fraction (0…1); nil when missing or an unsettled
    /// rollover reading that would misattribute the old window's usage.
    let s: Double?
    /// Weekly window used fraction (0…1).
    let w: Double?
    /// 5-hour window reset; nil while the window is idle (not started).
    let r: Date?

    init(t: Date, s: Double?, w: Double?, r: Date?) {
        self.t = t
        self.s = s.map { Self.rounded($0) }
        self.w = w.map { Self.rounded($0) }
        self.r = r
    }

    /// The sample worth keeping from `snapshot`, or nil when it carries no
    /// window reading at all.
    init?(snapshot: QuotaSnapshot) {
        let fiveHour = snapshot.fiveHour
        let settling = snapshot.isUnsettledRolloverReading(windowDuration: snapshot.tool.windowDuration)
        let idle = fiveHour?.isIdle ?? true
        let session: Double? = settling ? nil : fiveHour.map { 1 - $0.remainingFraction }
        let weekly = snapshot.weekly.map { 1 - $0.remainingFraction }
        guard session != nil || weekly != nil else { return nil }
        self.init(t: snapshot.fetchedAt, s: session, w: weekly, r: idle ? nil : fiveHour?.resetAt)
    }

    private static func rounded(_ value: Double) -> Double {
        (min(max(value, 0), 1) * 1000).rounded() / 1000
    }
}

/// One 5-hour window reconstructed from samples.
struct QuotaWindowSummary: Identifiable, Equatable {
    let resetAt: Date
    let duration: TimeInterval
    /// Highest used fraction seen while the window was open.
    let peakUsed: Double
    let samples: Int

    var startAt: Date { resetAt.addingTimeInterval(-duration) }
    var id: Date { resetAt }
    /// The window ran into (or right up to) its limit.
    var hitLimit: Bool { peakUsed >= 0.95 }
}

/// Totals shown in the History tab's stat row.
struct UsageHistoryStats: Equatable {
    let windowCount: Int
    let averagePeak: Double?
    let limitHits: Int
    let latestWeekly: Double?
}

enum UsageHistory {
    /// Retention for stored samples.
    static let retention: TimeInterval = 90 * 24 * 3600
    /// Samples closer together than this are bursts (claim verification,
    /// settle re-polls) and add nothing to the chart.
    static let minimumSpacing: TimeInterval = 60

    /// Groups samples into windows by their reset time. A provider can report a
    /// reset that drifts by seconds between polls (Codex `reset_after_seconds`),
    /// so resets within `tolerance` of the window's first reset are the same
    /// window; real windows are at least a full window duration apart.
    static func windows(
        from samples: [QuotaSample],
        duration: TimeInterval,
        tolerance: TimeInterval = 15 * 60
    ) -> [QuotaWindowSummary] {
        var result: [QuotaWindowSummary] = []
        var anchor: Date?
        var peak = 0.0
        var count = 0

        func flush() {
            if let anchor, count > 0 {
                result.append(QuotaWindowSummary(resetAt: anchor, duration: duration, peakUsed: peak, samples: count))
            }
        }

        let open = samples
            .filter { $0.r != nil && $0.s != nil }
            .sorted { $0.t < $1.t }
        for sample in open {
            guard let reset = sample.r, let used = sample.s else { continue }
            // A reading taken after its own reset belongs to no open window.
            guard sample.t <= reset else { continue }
            if let current = anchor, abs(reset.timeIntervalSince(current)) <= tolerance {
                peak = max(peak, used)
                count += 1
            } else {
                flush()
                anchor = reset
                peak = used
                count = 1
            }
        }
        flush()
        return result
    }

    static func stats(samples: [QuotaSample], windows: [QuotaWindowSummary]) -> UsageHistoryStats {
        let peaks = windows.map(\.peakUsed)
        return UsageHistoryStats(
            windowCount: windows.count,
            averagePeak: peaks.isEmpty ? nil : peaks.reduce(0, +) / Double(peaks.count),
            limitHits: windows.filter(\.hitLimit).count,
            latestWeekly: samples.max { $0.t < $1.t }?.w
        )
    }

    struct ChartPoint: Identifiable, Equatable {
        let t: Date
        let value: Double
        /// Consecutive points share a segment; a gap (app off, Mac asleep)
        /// starts a new one so the line isn't drawn across missing time.
        let segment: Int
        var id: String { "\(segment)-\(t.timeIntervalSince1970)" }
    }

    /// Chart points for one series (`value` returns nil to skip a sample).
    static func chartPoints(
        _ samples: [QuotaSample],
        maxGap: TimeInterval = 45 * 60,
        value: (QuotaSample) -> Double?
    ) -> [ChartPoint] {
        var points: [ChartPoint] = []
        var segment = 0
        var last: Date?
        for sample in samples.sorted(by: { $0.t < $1.t }) {
            guard let v = value(sample) else { continue }
            if let last, sample.t.timeIntervalSince(last) > maxGap { segment += 1 }
            points.append(ChartPoint(t: sample.t, value: v, segment: segment))
            last = sample.t
        }
        return points
    }

    // MARK: - Busy hours

    /// Tokens per (weekday, hour) over `hours` at or after `since`: 168 cells,
    /// index `(weekday - 1) * 24 + hour`, Sunday = weekday 1 as `Calendar`
    /// numbers them.
    static func hourOfWeek(_ hours: [TokenUsageHour], since: Date, calendar: Calendar) -> [Int] {
        var cells = [Int](repeating: 0, count: 7 * 24)
        for entry in hours where entry.hour >= since {
            let parts = calendar.dateComponents([.weekday, .hour], from: entry.hour)
            guard let weekday = parts.weekday, let hour = parts.hour,
                  (1...7).contains(weekday), (0..<24).contains(hour) else { continue }
            cells[(weekday - 1) * 24 + hour] += entry.tokens
        }
        return cells
    }

    struct DayRow: Equatable {
        let day: Date
        /// 24 cells, one per local hour; nil for an hour that hasn't come yet.
        let cells: [Int?]
    }

    /// The last `days` calendar days (today last), each with its 24 real hours.
    static func dayRows(_ hours: [TokenUsageHour], days: Int, now: Date, calendar: Calendar) -> [DayRow] {
        let today = calendar.startOfDay(for: now)
        let byHour = Dictionary(hours.map { ($0.hour, $0.tokens) }, uniquingKeysWith: +)
        return (0..<days).reversed().compactMap { back -> DayRow? in
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            let cells: [Int?] = (0..<24).map { hour in
                guard let start = calendar.date(byAdding: .hour, value: hour, to: day) else { return nil }
                if start > now { return nil }
                return byHour[start] ?? 0
            }
            return DayRow(day: day, cells: cells)
        }
    }

    /// The `count` clock hours ending with the current one, oldest first.
    static func recentHours(_ hours: [TokenUsageHour], count: Int, now: Date, calendar: Calendar) -> [TokenUsageHour] {
        guard let current = calendar.dateInterval(of: .hour, for: now)?.start else { return [] }
        let byHourEntry = Dictionary(grouping: hours, by: \.hour)
        return (0..<count).reversed().compactMap { back in
            calendar.date(byAdding: .hour, value: -back, to: current).map {
                total(byHourEntry[$0] ?? [], at: $0)
            }
        }
    }

    /// One entry per local calendar day for the last `days` days (today
    /// last), summing that day's hours.
    static func dayTotals(_ hours: [TokenUsageHour], days: Int, now: Date, calendar: Calendar) -> [TokenUsageHour] {
        let today = calendar.startOfDay(for: now)
        let byDay = Dictionary(grouping: hours) { calendar.startOfDay(for: $0.hour) }
        return (0..<days).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: today).map { total(byDay[$0] ?? [], at: $0) }
        }
    }

    /// Adds several accounts' hourly series together.
    static func mergeHourly(_ series: [[TokenUsageHour]]) -> [TokenUsageHour] {
        Dictionary(grouping: series.joined(), by: \.hour)
            .map { total($0.value, at: $0.key) }
            .sorted { $0.hour < $1.hour }
    }

    /// Sums entries; the cost is unknown (nil) once any entry with tokens
    /// has an unknown cost, so a partly unpriced total never looks complete.
    static func total(_ entries: [TokenUsageHour], at hour: Date) -> TokenUsageHour {
        let tokens = entries.reduce(0) { $0 + $1.tokens }
        let unpriced = entries.contains { $0.tokens > 0 && $0.costUSD == nil }
        let cost = unpriced ? nil : entries.reduce(0.0) { $0 + ($1.costUSD ?? 0) }
        return TokenUsageHour(hour: hour, tokens: tokens, costUSD: cost)
    }

    /// Whether `sample` should be appended after `last` (nil = first sample).
    static func shouldRecord(_ sample: QuotaSample, after last: QuotaSample?) -> Bool {
        guard let last else { return true }
        if sample.t.timeIntervalSince(last.t) >= minimumSpacing { return true }
        // Within a burst, keep only a reading that starts a new window.
        return sample.r != nil && last.r.map { abs(sample.r!.timeIntervalSince($0)) > 15 * 60 } ?? true
    }
}

/// Persists `QuotaSample`s as one JSON-lines file per account under
/// `~/Library/Application Support/QuotaWarmer/history/`. Appends are cheap;
/// old lines are pruned once per launch per account, on first read.
final class UsageHistoryStore: @unchecked Sendable {
    static let shared = UsageHistoryStore()

    private let queue = DispatchQueue(label: "com.quotawarmer.usage-history")
    private let directory: URL
    private var cache: [String: [QuotaSample]] = [:]
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = support.appendingPathComponent("QuotaWarmer/history", isDirectory: true)
        }
    }

    func record(_ snapshot: QuotaSnapshot, for provider: ProviderID) {
        guard let sample = QuotaSample(snapshot: snapshot) else { return }
        record(sample, storageKey: provider.storageKey)
    }

    func record(_ sample: QuotaSample, storageKey: String) {
        queue.async {
            var samples = self.loadLocked(storageKey)
            guard UsageHistory.shouldRecord(sample, after: samples.last) else { return }
            samples.append(sample)
            self.cache[storageKey] = samples
            self.appendLocked(sample, storageKey: storageKey)
        }
    }

    func samples(for provider: ProviderID, since: Date) async -> [QuotaSample] {
        await samples(storageKey: provider.storageKey, since: since)
    }

    func samples(storageKey: String, since: Date) async -> [QuotaSample] {
        await withCheckedContinuation { continuation in
            queue.async {
                let all = self.loadLocked(storageKey)
                continuation.resume(returning: all.filter { $0.t >= since })
            }
        }
    }

    func removeAll(for provider: ProviderID) {
        let key = provider.storageKey
        queue.async {
            self.cache[key] = nil
            try? FileManager.default.removeItem(at: self.fileURL(key))
        }
    }

    // MARK: - Queue-confined

    private func fileURL(_ storageKey: String) -> URL {
        directory.appendingPathComponent("\(storageKey).jsonl")
    }

    private func loadLocked(_ storageKey: String) -> [QuotaSample] {
        if let cached = cache[storageKey] { return cached }
        let url = fileURL(storageKey)
        var samples: [QuotaSample] = []
        var dropped = false
        let cutoff = Date().addingTimeInterval(-UsageHistory.retention)
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                guard let sample = try? decoder.decode(QuotaSample.self, from: Data(line.utf8)) else {
                    dropped = true
                    continue
                }
                if sample.t < cutoff { dropped = true; continue }
                samples.append(sample)
            }
        }
        samples.sort { $0.t < $1.t }
        if dropped { rewriteLocked(samples, storageKey: storageKey) }
        cache[storageKey] = samples
        return samples
    }

    private func appendLocked(_ sample: QuotaSample, storageKey: String) {
        guard var line = try? encoder.encode(sample) else { return }
        line.append(0x0A)
        let url = fileURL(storageKey)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url, options: .atomic)
            }
        } catch {
            DiagnosticLogger.append("usage_history_write_failed key=\(storageKey)")
        }
    }

    private func rewriteLocked(_ samples: [QuotaSample], storageKey: String) {
        var data = Data()
        for sample in samples {
            guard let line = try? encoder.encode(sample) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL(storageKey), options: .atomic)
        } catch {
            DiagnosticLogger.append("usage_history_rewrite_failed key=\(storageKey)")
        }
    }
}
