import Foundation

/// How a warm-up (or its claim receipt) ended. Stored on `HistoryEvent` so the
/// ROI panel can count claimed windows from the persisted log.
enum EventOutcome: String, Codable {
    case sent        // CLI command completed, window not yet verified
    case confirmed   // live quota showed the window open
    case missed      // command completed but quota never showed the window
    case failed      // the command itself failed
    case skipped     // a warm-up was deliberately not run
}

/// What triggered a warm-up. Stored on the warm-up's events so the Impact panel
/// can split claimed windows without parsing titles.
enum WarmupSource: String, Codable, CaseIterable {
    case auto, morning, manual, intent

    /// Maps `AppState.triggerWarmup`'s `mode` string.
    init(mode: String) {
        switch mode {
        case "auto": self = .auto
        case "scheduled", "scheduled-catchup": self = .morning
        case "intent": self = .intent
        default: self = .manual
        }
    }
}

struct HistoryEvent: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let tool: ProviderID?
    let kind: HistoryKind
    let title: String
    let detail: String
    /// Structured warm-up fields; nil on events that are not about a warm-up.
    var outcome: EventOutcome?
    /// The quota window's `rawWindowKey`, when known.
    var windowKey: String?
    var windowResetAt: Date?
    var model: String?
    /// What triggered the warm-up; nil on older lines and non-warm-up events.
    var source: WarmupSource?

    init(
        id: UUID = UUID(), timestamp: Date = Date(), tool: ProviderID?, kind: HistoryKind,
        title: String, detail: String, outcome: EventOutcome? = nil,
        windowKey: String? = nil, windowResetAt: Date? = nil, model: String? = nil,
        source: WarmupSource? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.tool = tool
        self.kind = kind
        self.title = title
        self.detail = detail
        self.outcome = outcome
        self.windowKey = windowKey
        self.windowResetAt = windowResetAt
        self.model = model
        self.source = source
    }

    // Stable on-disk schema: the provider is its storageKey string.
    private enum CodingKeys: String, CodingKey {
        case id, t, provider, kind, title, detail, outcome, windowKey, resetAt, model, source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        timestamp = Date(timeIntervalSince1970: try c.decode(TimeInterval.self, forKey: .t))
        tool = try c.decodeIfPresent(String.self, forKey: .provider).flatMap(ProviderID.fromStorageKey)
        kind = try c.decode(HistoryKind.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        detail = try c.decode(String.self, forKey: .detail)
        outcome = try c.decodeIfPresent(EventOutcome.self, forKey: .outcome)
        windowKey = try c.decodeIfPresent(String.self, forKey: .windowKey)
        windowResetAt = try c.decodeIfPresent(TimeInterval.self, forKey: .resetAt).map(Date.init(timeIntervalSince1970:))
        model = try c.decodeIfPresent(String.self, forKey: .model)
        // An unknown future source value must not drop the whole event.
        source = (try? c.decodeIfPresent(WarmupSource.self, forKey: .source)) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(timestamp.timeIntervalSince1970, forKey: .t)
        try c.encodeIfPresent(tool?.storageKey, forKey: .provider)
        try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        try c.encode(detail, forKey: .detail)
        try c.encodeIfPresent(outcome, forKey: .outcome)
        try c.encodeIfPresent(windowKey, forKey: .windowKey)
        try c.encodeIfPresent(windowResetAt?.timeIntervalSince1970, forKey: .resetAt)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(source, forKey: .source)
    }

    static func == (lhs: HistoryEvent, rhs: HistoryEvent) -> Bool { lhs.id == rhs.id }
}

extension ProviderID {
    /// Inverse of `storageKey` (`claude` or `claude.<id>`). The account's home
    /// and display name are not recoverable from the key; callers that need
    /// them look the account up by `storageKey`.
    static func fromStorageKey(_ key: String) -> ProviderID? {
        let parts = key.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, let kind = ToolID(rawValue: String(first)) else { return nil }
        if parts.count == 1 { return .default(kind) }
        let account = String(parts[1])
        return account.isEmpty ? nil : ProviderID(kind: kind, accountID: account)
    }
}

/// Provider + kind filter for the Recent Events list.
struct EventFilter: Equatable {
    enum Group: String, CaseIterable {
        case all = "All"
        case warmups = "Warm-ups"
        case quota = "Quota"
        case problems = "Problems"
        case other = "Other"

        /// Localized picker label; `rawValue` stays English for persisted state.
        var title: String {
            switch self {
            case .all: return String(localized: "All")
            case .warmups: return String(localized: "Warm-ups")
            case .quota: return String(localized: "Quota")
            case .problems: return String(localized: "Problems")
            case .other: return String(localized: "Other")
            }
        }

        func contains(_ kind: HistoryKind) -> Bool {
            switch self {
            case .all: return true
            case .warmups: return kind == .autoWarmup || kind == .manualWarmup || kind == .resetDetected
            case .quota: return kind == .quotaFetch
            case .problems: return kind == .authFailure || kind == .rateLimit || kind == .pollingError
            case .other: return kind == .updateCheck
            }
        }
    }

    /// Provider storageKey; nil = every provider.
    var providerKey: String?
    var group: Group = .all

    func matches(_ event: HistoryEvent) -> Bool {
        if let providerKey, event.tool?.storageKey != providerKey { return false }
        return group.contains(event.kind)
    }
}

/// Append-only JSONL event log at `…/QuotaWarmer/events.jsonl`. Every method is
/// safe to call from any thread; file work is confined to a serial queue.
final class EventLogStore: @unchecked Sendable {
    static let shared = EventLogStore()

    static let retention: TimeInterval = 90 * 24 * 3600
    static let maxLines = 5_000

    private let directory: URL
    private let queue = DispatchQueue(label: "QuotaWarmer.EventLogStore")
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = support.appendingPathComponent("QuotaWarmer", isDirectory: true)
        }
    }

    var fileURL: URL { directory.appendingPathComponent("events.jsonl") }

    func append(_ event: HistoryEvent) {
        queue.async {
            guard var line = try? self.encoder.encode(event) else { return }
            line.append(0x0A)
            do {
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                if let handle = try? FileHandle(forWritingTo: self.fileURL) {
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: line)
                } else {
                    try line.write(to: self.fileURL, options: .atomic)
                }
            } catch {
                DiagnosticLogger.append("event_log_write_failed")
            }
        }
    }

    /// Reads the log, drops corrupt/expired lines and anything beyond the cap
    /// (oldest first), rewrites the file if anything was dropped, and returns
    /// the events oldest-first. Call once on launch.
    func loadAndPrune(now: Date = Date()) async -> [HistoryEvent] {
        await withCheckedContinuation { continuation in
            queue.async {
                let text = (try? String(contentsOf: self.fileURL, encoding: .utf8)) ?? ""
                let parsed = Self.parse(text, decoder: self.decoder)
                let kept = Self.prune(parsed.events, now: now)
                if parsed.corrupt > 0 || kept.count != parsed.events.count {
                    self.rewriteLocked(kept)
                }
                continuation.resume(returning: kept)
            }
        }
    }

    /// The newest `limit` events, oldest-first (reads the file; for exports).
    func recent(limit: Int) async -> [HistoryEvent] {
        await withCheckedContinuation { continuation in
            queue.async {
                let text = (try? String(contentsOf: self.fileURL, encoding: .utf8)) ?? ""
                let events = Self.parse(text, decoder: self.decoder).events
                continuation.resume(returning: Array(events.suffix(limit)))
            }
        }
    }

    /// Forgets a removed account's events (matches `UsageHistoryStore.removeAll`).
    func removeAll(for provider: ProviderID) {
        let key = provider.storageKey
        queue.async {
            guard let text = try? String(contentsOf: self.fileURL, encoding: .utf8) else { return }
            let events = Self.parse(text, decoder: self.decoder).events
            let kept = events.filter { $0.tool?.storageKey != key }
            if kept.count != events.count { self.rewriteLocked(kept) }
        }
    }

    /// Blocks until queued writes have landed (tests, export).
    func flush() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    // MARK: - Pure helpers

    /// Decodes JSONL, skipping lines that are not valid events.
    static func parse(_ text: String, decoder: JSONDecoder = JSONDecoder()) -> (events: [HistoryEvent], corrupt: Int) {
        var events: [HistoryEvent] = []
        var corrupt = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let event = try? decoder.decode(HistoryEvent.self, from: Data(line.utf8)) {
                events.append(event)
            } else {
                corrupt += 1
            }
        }
        return (events, corrupt)
    }

    /// Drops events older than `retention`, then keeps only the newest
    /// `maxLines`. Result is oldest-first.
    static func prune(
        _ events: [HistoryEvent], now: Date,
        retention: TimeInterval = EventLogStore.retention, maxLines: Int = EventLogStore.maxLines
    ) -> [HistoryEvent] {
        let cutoff = now.addingTimeInterval(-retention)
        let sorted = events.filter { $0.timestamp >= cutoff }.sorted { $0.timestamp < $1.timestamp }
        return sorted.count > maxLines ? Array(sorted.suffix(maxLines)) : sorted
    }

    private func rewriteLocked(_ events: [HistoryEvent]) {
        var data = Data()
        for event in events {
            guard let line = try? encoder.encode(event) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            DiagnosticLogger.append("event_log_rewrite_failed")
        }
    }
}
