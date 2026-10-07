import Foundation

/// Scans the CLIs' local JSONL logs for token usage. Keep one instance per tool
/// for the app's lifetime: it caches each file's parsed records and, because
/// the logs are append-only, re-reads only bytes appended since the last scan.
/// A 30-day Codex history is ~1 GB; a full re-read cost ~30 s of CPU and
/// ~700 MB of memory every refresh, an incremental one milliseconds.
/// Not safe for concurrent `usage` calls on one instance (AppState single-
/// flights each tool's scan).
final class LocalUsageProvider: @unchecked Sendable {
    struct UsageRecord {
        let date: Date
        let model: String?
        let inputTokens: Int
        let cacheCreationFiveMinuteTokens: Int
        let cacheCreationOneHourTokens: Int
        let cacheReadTokens: Int
        let cachedInputTokens: Int
        let outputTokens: Int
        let totalTokens: Int
        let explicitCostUSD: Double?
    }

    private struct UsageBucket {
        var tokens = 0
        var costUSD: Double?
        var hasUnpricedUsage = false

        mutating func add(tokens: Int, cost: Double?) {
            self.tokens += tokens
            guard let cost else {
                if tokens > 0 { hasUnpricedUsage = true }
                return
            }
            self.costUSD = (self.costUSD ?? 0) + cost
        }

        /// Priced share of a bucket whose total cost is unavailable.
        var partialCostUSD: Double? {
            guard hasUnpricedUsage, let costUSD, costUSD > 0 else { return nil }
            return costUSD
        }

        mutating func merge(_ other: UsageBucket) {
            tokens += other.tokens
            if let cost = other.costUSD { costUSD = (costUSD ?? 0) + cost }
            if other.hasUnpricedUsage { hasUnpricedUsage = true }
        }

        var estimatedCostUSD: Double? {
            if tokens == 0 { return 0 }
            return hasUnpricedUsage ? nil : costUSD
        }
    }

    private struct ModelRates {
        let input: Double
        let cacheWriteFiveMinute: Double
        let cacheWriteOneHour: Double
        let cacheRead: Double
        let output: Double
    }

    private let fileManager: FileManager
    private let calendar: Calendar
    /// A usage record plus the identity Claude records are de-duplicated by.
    private struct CachedRecord {
        let id: String?
        let record: UsageRecord
        /// `calendar.startOfDay(for: record.date)`, computed once at parse time
        /// (it dominated re-scan time when recomputed for every record).
        let day: Date
    }

    /// Parsed state of one JSONL file, reused while the file is unchanged and
    /// extended from `parsedBytes` when it only grew.
    private struct FileScan {
        var size: Int
        var modified: Date
        /// Offset just past the last newline consumed.
        var parsedBytes = 0
        /// Non-empty complete lines consumed (Claude fallback record ids).
        var lineCount = 0
        /// Codex: the model in effect at `parsedBytes`.
        var codexModel: String?
        var records: [CachedRecord] = []
        /// From an unterminated last line (still being written); re-read on
        /// the next change instead of being committed twice.
        var tailRecords: [CachedRecord] = []

        var allRecords: [CachedRecord] { records + tailRecords }
    }

    private var fileScans: [String: FileScan] = [:]
    /// Catalog lookups per model string for the current `usage` call (tens of
    /// thousands of records share a handful of models; the catalog may change
    /// between calls, so this is cleared each time).
    private var entryCache: [String: ModelCatalog.Model?] = [:]
    private static let readChunkSize = 1 << 20
    private static let claudeMarkers: [[UInt8]] = [Array(#""usage""#.utf8)]
    private static let codexMarkers: [[UInt8]] = [
        Array(#""token_count""#.utf8),
        Array(#""model""#.utf8),
        Array(#""model_name""#.utf8)
    ]

    private let claudeCatalog: ModelCatalogStore
    private let codexCatalog: ModelCatalogStore
    /// Model ids seen in this scan that the catalog could not price.
    private var unpricedModels = Set<String>()

    /// Codex and Claude JSONL timestamps are ISO-8601 UTC values. Keep the
    /// displayed day buckets aligned with the log's calendar rather than the
    /// Mac's local timezone.
    private static var logCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private let iso8601Frac: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    init(
        fileManager: FileManager = .default,
        calendar: Calendar? = nil,
        claudeCatalog: ModelCatalogStore = .claude,
        codexCatalog: ModelCatalogStore = .codex
    ) {
        self.fileManager = fileManager
        self.calendar = calendar ?? Self.logCalendar
        self.claudeCatalog = claudeCatalog
        self.codexCatalog = codexCatalog
    }

    func usage(for tool: ToolID, baseURL: URL? = nil, now: Date = Date()) -> TokenUsageSummary {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let since = calendar.date(byAdding: .day, value: -30, to: today) ?? today
        let root = baseURL ?? tool.logDirectoryURL

        let buckets: [Date: UsageBucket]
        let records: [CachedRecord]
        if let root, fileManager.fileExists(atPath: root.path) {
            switch tool {
            case .claude:
                unpricedModels.removeAll()
                entryCache.removeAll()
                records = claudeRecords(in: root, since: since)
                buckets = self.buckets(from: records, pricing: claudeCost)
                if !unpricedModels.isEmpty { claudeCatalog.reportUnpricedModels(unpricedModels) }
            case .codex:
                unpricedModels.removeAll()
                entryCache.removeAll()
                records = codexRecords(in: root, since: since)
                buckets = self.buckets(from: records, pricing: codexCost)
                if !unpricedModels.isEmpty { codexCatalog.reportUnpricedModels(unpricedModels) }
            }
        } else {
            buckets = [:]
            records = []
        }

        let todayBucket = buckets[today] ?? UsageBucket()
        let yesterdayBucket = buckets[yesterday] ?? UsageBucket()
        let last30Bucket = buckets
            .filter { $0.key >= since && $0.key <= today }
            .reduce(into: UsageBucket()) { aggregate, entry in aggregate.merge(entry.value) }

        return TokenUsageSummary(
            fetchedAt: now,
            source: tool == .claude ? "Claude local usage" : "Codex local usage",
            today: TokenUsageDay(date: today, totalTokens: todayBucket.tokens, costUSD: todayBucket.estimatedCostUSD, partialCostUSD: todayBucket.partialCostUSD),
            yesterday: TokenUsageDay(date: yesterday, totalTokens: yesterdayBucket.tokens, costUSD: yesterdayBucket.estimatedCostUSD, partialCostUSD: yesterdayBucket.partialCostUSD),
            last30Days: TokenUsageDay(date: since, totalTokens: last30Bucket.tokens, costUSD: last30Bucket.estimatedCostUSD, partialCostUSD: last30Bucket.partialCostUSD),
            hourly: Self.hourly(
                records.map(\.record),
                calendar: hourCalendar,
                cost: tool == .claude ? claudeCost : codexCost
            )
        )
    }

    /// Calendar for the History buckets: the user's local time, since "when
    /// do I work" is a local-clock question (today/yesterday stay UTC days).
    var hourCalendar: Calendar = .current

    /// Tokens and cost per clock hour (start of the hour in `calendar`),
    /// oldest first; the History charts build every range from these.
    static func hourly(_ records: [UsageRecord], calendar: Calendar, cost: (UsageRecord) -> Double?) -> [TokenUsageHour] {
        var buckets: [Date: UsageBucket] = [:]
        for record in records where record.totalTokens > 0 {
            guard let start = calendar.dateInterval(of: .hour, for: record.date)?.start else { continue }
            buckets[start, default: UsageBucket()].add(tokens: record.totalTokens, cost: record.explicitCostUSD ?? cost(record))
        }
        return buckets
            .map { TokenUsageHour(hour: $0.key, tokens: $0.value.tokens, costUSD: $0.value.estimatedCostUSD) }
            .sorted { $0.hour < $1.hour }
    }

    private func claudeRecords(in root: URL, since: Date) -> [CachedRecord] {
        var recordsByID: [String: CachedRecord] = [:]
        for scan in scanFiles(in: root, tool: .claude, since: since) {
            for cached in scan.allRecords where cached.record.date >= since {
                guard let id = cached.id else { continue }
                if let existing = recordsByID[id], existing.record.totalTokens >= cached.record.totalTokens { continue }
                recordsByID[id] = cached
            }
        }
        return Array(recordsByID.values)
    }

    private func codexRecords(in root: URL, since: Date) -> [CachedRecord] {
        scanFiles(in: root, tool: .codex, since: since)
            .flatMap(\.allRecords)
            .filter { $0.record.date >= since }
    }

    /// Up-to-date scans of every log file touched since `since`, in enumeration
    /// order. Cached scans of files that dropped out (deleted or too old) are
    /// released.
    private func scanFiles(in root: URL, tool: ToolID, since: Date) -> [FileScan] {
        let prefix = "\(tool.rawValue):\(root.standardizedFileURL.path)/"
        var seen = Set<String>()
        var scans: [FileScan] = []
        enumerateJSONL(in: root, since: since) { url, size, modified in
            let key = "\(tool.rawValue):\(url.standardizedFileURL.path)"
            seen.insert(key)
            let scan = updatedScan(of: url, key: key, tool: tool, size: size, modified: modified)
            fileScans[key] = scan
            scans.append(scan)
        }
        for key in fileScans.keys where key.hasPrefix(prefix) && !seen.contains(key) {
            fileScans[key] = nil
        }
        return scans
    }

    private func updatedScan(of url: URL, key: String, tool: ToolID, size: Int, modified: Date) -> FileScan {
        if let cached = fileScans[key], cached.size == size, cached.modified == modified {
            return cached
        }
        var scan: FileScan
        if let cached = fileScans[key], size >= cached.parsedBytes {
            // Appended to: keep what was parsed, re-read from the last newline.
            scan = cached
            scan.tailRecords = []
        } else {
            // New, truncated, or rewritten: parse from the start.
            scan = FileScan(size: size, modified: modified)
        }
        scan.size = size
        scan.modified = modified

        let markers = tool == .claude ? Self.claudeMarkers : Self.codexMarkers
        let consumed = readLines(of: url, from: scan.parsedBytes) { line, terminated in
            guard line.count > 0 else { return }
            let index = scan.lineCount
            if terminated { scan.lineCount += 1 }
            guard Self.contains(line, anyOf: markers),
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return }
            let parsed: CachedRecord?
            switch tool {
            case .claude:
                parsed = date(from: object)
                    .flatMap { claudeRecord(from: object, date: $0) }
                    .map { CachedRecord(id: claudeIdentity(from: object) ?? "\(url.path)#\(index)", record: $0, day: calendar.startOfDay(for: $0.date)) }
            case .codex:
                // A tail line sees the committed model but never commits its own.
                let model = model(from: object) ?? scan.codexModel
                if terminated { scan.codexModel = model }
                parsed = date(from: object)
                    .flatMap { codexRecord(from: object, date: $0, model: model) }
                    .map { CachedRecord(id: nil, record: $0, day: calendar.startOfDay(for: $0.date)) }
            }
            guard let parsed else { return }
            if terminated { scan.records.append(parsed) } else { scan.tailRecords.append(parsed) }
        }
        if let consumed { scan.parsedBytes = consumed }
        return scan
    }

    /// Streams `url` from `offset` in 1 MB chunks, calling `body` with each
    /// line's bytes (newline excluded). A final line without a newline is
    /// passed with `terminated == false`. Returns the offset just past the last
    /// newline, or nil when the file cannot be read.
    private func readLines(
        of url: URL,
        from offset: Int,
        _ body: (UnsafeRawBufferPointer, _ terminated: Bool) -> Void
    ) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: UInt64(offset)) } catch { return nil }

        var pending: [UInt8] = []
        var consumed = offset
        var reachedEnd = false
        while !reachedEnd {
            // Drain JSONSerialization's autoreleased objects per chunk; without
            // this a large file's objects pile up until the whole scan returns.
            autoreleasepool {
                guard let chunk = try? handle.read(upToCount: Self.readChunkSize), !chunk.isEmpty else {
                    reachedEnd = true
                    return
                }
                pending.append(contentsOf: chunk)
                var lineStart = 0
                pending.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    while lineStart < raw.count,
                          let newline = memchr(base + lineStart, 0x0A, raw.count - lineStart) {
                        let lineEnd = base.distance(to: UnsafeRawPointer(newline))
                        body(UnsafeRawBufferPointer(rebasing: raw[lineStart..<lineEnd]), true)
                        lineStart = lineEnd + 1
                    }
                }
                consumed += lineStart
                pending.removeFirst(lineStart)
            }
        }
        if !pending.isEmpty {
            pending.withUnsafeBytes { body($0, false) }
        }
        return consumed
    }

    /// Cheap pre-filter before JSON parsing: most log lines (tool output,
    /// response text) can never produce a record.
    private static func contains(_ line: UnsafeRawBufferPointer, anyOf markers: [[UInt8]]) -> Bool {
        guard let base = line.baseAddress else { return false }
        return markers.contains { marker in
            marker.withUnsafeBytes { needle in
                memmem(base, line.count, needle.baseAddress, needle.count) != nil
            }
        }
    }

    private func buckets(
        from records: [CachedRecord],
        pricing: (UsageRecord) -> Double?
    ) -> [Date: UsageBucket] {
        records.reduce(into: [Date: UsageBucket]()) { buckets, cached in
            let cost = cached.record.explicitCostUSD ?? pricing(cached.record)
            buckets[cached.day, default: UsageBucket()].add(tokens: cached.record.totalTokens, cost: cost)
        }
    }

    private func claudeRecord(from object: [String: Any], date: Date) -> UsageRecord? {
        guard let usage = usageObject(from: object) else { return nil }
        let input = intValue(usage["input_tokens"])
        let breakdown = cacheCreationBreakdown(from: usage)
        let fallbackCacheCreation = intValue(usage["cache_creation_input_tokens"])
        let cacheCreation = breakdown.total > 0 ? breakdown.total : fallbackCacheCreation
        let cacheCreationFiveMinute = breakdown.total > 0 ? breakdown.fiveMinute : cacheCreation
        let cacheCreationOneHour = breakdown.oneHour
        let cacheRead = intValue(usage["cache_read_input_tokens"])
        let output = intValue(usage["output_tokens"])
        let total = input + cacheCreation + cacheRead + output
        guard total > 0 else { return nil }

        return UsageRecord(
            date: date,
            model: model(from: object),
            inputTokens: input,
            cacheCreationFiveMinuteTokens: cacheCreationFiveMinute,
            cacheCreationOneHourTokens: cacheCreationOneHour,
            cacheReadTokens: cacheRead,
            cachedInputTokens: 0,
            outputTokens: output,
            totalTokens: total,
            explicitCostUSD: explicitCost(from: object)
        )
    }

    private func codexRecord(from object: [String: Any], date: Date, model: String?) -> UsageRecord? {
        guard let payload = object["payload"] as? [String: Any],
              let type = payload["type"] as? String,
              type == "token_count",
              let info = payload["info"] as? [String: Any],
              let usage = info["last_token_usage"] as? [String: Any] else { return nil }

        let input = intValue(usage["input_tokens"])
        let cached = intValue(usage["cached_input_tokens"])
        let output = intValue(usage["output_tokens"])
        let total = intValue(usage["total_tokens"])
        let resolvedTotal = total > 0 ? total : input + output
        guard resolvedTotal > 0 else { return nil }

        return UsageRecord(
            date: date,
            model: model,
            inputTokens: input,
            cacheCreationFiveMinuteTokens: 0,
            cacheCreationOneHourTokens: 0,
            cacheReadTokens: 0,
            cachedInputTokens: cached,
            outputTokens: output,
            totalTokens: resolvedTotal,
            explicitCostUSD: explicitCost(from: object)
        )
    }

    private func claudeCost(_ record: UsageRecord) -> Double? {
        guard let rates = claudeRates(for: record.model) else { return nil }
        return cost(
            inputTokens: record.inputTokens,
            cacheCreationFiveMinuteTokens: record.cacheCreationFiveMinuteTokens,
            cacheCreationOneHourTokens: record.cacheCreationOneHourTokens,
            cacheReadTokens: record.cacheReadTokens,
            outputTokens: record.outputTokens,
            rates: rates
        )
    }

    private func codexCost(_ record: UsageRecord) -> Double? {
        // Older Codex Desktop/VSCodium session files omit the model entirely.
        // Their token-count shape is still authoritative, so they are priced as
        // the catalog's `unlabeledModel`. An unknown model string remains
        // unavailable rather than being silently priced as a different model.
        guard let catalog = codexCatalog.catalog else { return nil }
        guard let entry = cachedEntry(record.model ?? catalog.unlabeledModel, in: catalog) else {
            if let model = record.model, !model.isEmpty { unpricedModels.insert(model) }
            return nil
        }
        let rates = rates(entry)
        let cached = min(record.cachedInputTokens, record.inputTokens)
        let uncached = max(0, record.inputTokens - cached)
        let longContext = catalog.longContext.flatMap { record.inputTokens > $0.inputTokensAbove ? $0 : nil }
        let inputMultiplier = longContext?.inputMultiplier ?? 1.0
        let outputMultiplier = longContext?.outputMultiplier ?? 1.0
        return ((Double(uncached) * rates.input * inputMultiplier)
            + (Double(cached) * rates.cacheRead * inputMultiplier)
            + (Double(record.outputTokens) * rates.output * outputMultiplier)) / 1_000_000
    }

    private func cost(
        inputTokens: Int,
        cacheCreationFiveMinuteTokens: Int,
        cacheCreationOneHourTokens: Int,
        cacheReadTokens: Int,
        outputTokens: Int,
        rates: ModelRates
    ) -> Double {
        ((Double(inputTokens) * rates.input)
            + (Double(cacheCreationFiveMinuteTokens) * rates.cacheWriteFiveMinute)
            + (Double(cacheCreationOneHourTokens) * rates.cacheWriteOneHour)
            + (Double(cacheReadTokens) * rates.cacheRead)
            + (Double(outputTokens) * rates.output)) / 1_000_000
    }

    /// Prices come from the tool's model catalog (`ModelCatalogStore`), so a
    /// new model or price change is picked up without an app release. A model
    /// the catalog cannot price stays unpriced (cost shown as unavailable) and
    /// is reported so the catalog refreshes early.
    private func cachedEntry(_ model: String?, in catalog: ModelCatalog) -> ModelCatalog.Model? {
        guard let model else { return nil }
        if let cached = entryCache[model] { return cached }
        let entry = catalog.model(for: model)
        entryCache[model] = entry
        return entry
    }

    private func claudeRates(for model: String?) -> ModelRates? {
        guard let model, !model.isEmpty else { return nil }
        guard let catalog = claudeCatalog.catalog, let entry = cachedEntry(model, in: catalog) else {
            // `<synthetic>` and similar placeholders are not real models.
            if !model.hasPrefix("<") { unpricedModels.insert(model) }
            return nil
        }
        return rates(entry)
    }

    private func rates(_ entry: ModelCatalog.Model) -> ModelRates {
        ModelRates(
            input: entry.input,
            cacheWriteFiveMinute: entry.cacheWrite5m,
            cacheWriteOneHour: entry.cacheWrite1h,
            cacheRead: entry.cacheRead,
            output: entry.output
        )
    }

    private func usageObject(from object: [String: Any]) -> [String: Any]? {
        if let usage = object["usage"] as? [String: Any] { return usage }
        if let message = object["message"] as? [String: Any],
           let usage = message["usage"] as? [String: Any] {
            return usage
        }
        if let message = claudeMessageObject(from: object),
           let usage = message["usage"] as? [String: Any] {
            return usage
        }
        return nil
    }

    private func claudeIdentity(from object: [String: Any]) -> String? {
        if let message = claudeMessageObject(from: object),
           let id = stringValue(message["id"]) {
            return id
        }
        if let envelope = claudeEnvelopeObject(from: object) {
            for key in ["messageID", "messageId", "requestId", "request_id", "uuid"] {
                if let value = stringValue(envelope[key]) { return value }
            }
        }
        for key in ["messageID", "messageId", "requestId", "uuid"] {
            if let value = stringValue(object[key]) { return value }
        }
        return nil
    }

    private func model(from object: [String: Any]) -> String? {
        if let value = stringValue(object["model"]) { return value }
        if let message = object["message"] as? [String: Any],
           let value = stringValue(message["model"]) {
            return value
        }
        if let message = claudeMessageObject(from: object),
           let value = stringValue(message["model"]) {
            return value
        }
        if let payload = object["payload"] as? [String: Any] {
            if let value = stringValue(payload["model"]) { return value }
            if let settings = payload["thread_settings"] as? [String: Any],
               let value = stringValue(settings["model"]) {
                return value
            }
            if let info = payload["info"] as? [String: Any] {
                if let value = stringValue(info["model"]) { return value }
                if let value = stringValue(info["model_name"]) { return value }
                if let metadata = info["metadata"] as? [String: Any],
                   let value = stringValue(metadata["model"]) {
                    return value
                }
            }
            if let nested = payload["payload"] as? [String: Any],
               let value = stringValue(nested["model"]) {
                return value
            }
        }
        if let provenance = object["provenance"] as? [String: Any],
           let value = stringValue(provenance["model"]) {
            return value
        }
        return nil
    }

    private func date(from object: [String: Any]) -> Date? {
        if let value = stringValue(object["timestamp"]) {
            return parseDate(value)
        }
        if let envelope = claudeEnvelopeObject(from: object),
           let value = stringValue(envelope["timestamp"]) {
            return parseDate(value)
        }
        if let payload = object["payload"] as? [String: Any],
           let value = stringValue(payload["timestamp"]) {
            return parseDate(value)
        }
        return nil
    }

    private func parseDate(_ value: String) -> Date? {
        iso8601Frac.date(from: value) ?? iso8601.date(from: value)
    }

    private func explicitCost(from object: [String: Any]) -> Double? {
        for key in ["totalCost", "costUSD"] {
            if let value = doubleValue(object[key]) { return value }
        }
        if let message = object["message"] as? [String: Any] {
            for key in ["totalCost", "costUSD"] {
                if let value = doubleValue(message[key]) { return value }
            }
        }
        if let envelope = claudeEnvelopeObject(from: object) {
            for key in ["totalCost", "costUSD"] {
                if let value = doubleValue(envelope[key]) { return value }
            }
        }
        if let message = claudeMessageObject(from: object) {
            for key in ["totalCost", "costUSD"] {
                if let value = doubleValue(message[key]) { return value }
            }
        }
        return nil
    }

    private func cacheCreationBreakdown(from usage: [String: Any]) -> (fiveMinute: Int, oneHour: Int, total: Int) {
        guard let cacheCreation = usage["cache_creation"] as? [String: Any] else {
            return (0, 0, 0)
        }
        let fiveMinute = intValue(cacheCreation["ephemeral_5m_input_tokens"])
        let oneHour = intValue(cacheCreation["ephemeral_1h_input_tokens"])
        return (fiveMinute, oneHour, fiveMinute + oneHour)
    }

    private func claudeEnvelopeObject(from object: [String: Any]) -> [String: Any]? {
        guard let data = object["data"] as? [String: Any],
              let envelope = data["message"] as? [String: Any] else { return nil }
        return envelope
    }

    private func claudeMessageObject(from object: [String: Any]) -> [String: Any]? {
        if let message = object["message"] as? [String: Any] {
            return message
        }
        if let envelope = claudeEnvelopeObject(from: object),
           let message = envelope["message"] as? [String: Any] {
            return message
        }
        return nil
    }

    private func enumerateJSONL(in directory: URL, since: Date, handler: (URL, Int, Date) -> Void) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }

        var count = 0
        for case let url as URL in enumerator {
            count += 1
            if count > 50_000 { break }
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  let modified = values.contentModificationDate,
                  modified >= since else { continue }
            handler(url, values.fileSize ?? 0, modified)
        }
    }

    private func intValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String, let double = Double(string) { return Int(double) }
        return 0
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string.isEmpty ? nil : string }
        return String(describing: value)
    }
}
