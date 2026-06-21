import Foundation

final class LocalUsageProvider {
    private struct UsageRecord {
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

        mutating func add(tokens: Int, cost: Double?) {
            self.tokens += tokens
            guard let cost else { return }
            self.costUSD = (self.costUSD ?? 0) + cost
        }
    }

    private struct ModelRates {
        let input: Double
        let cacheWrite: Double
        let cacheRead: Double
        let output: Double
        let cacheReadExplicit: Bool
    }

    private let fileManager: FileManager
    private let calendar: Calendar

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

    init(fileManager: FileManager = .default, calendar: Calendar = .current) {
        self.fileManager = fileManager
        self.calendar = calendar
    }

    func usage(for tool: ToolID, baseURL: URL? = nil, now: Date = Date()) -> TokenUsageSummary {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let since = calendar.date(byAdding: .day, value: -30, to: today) ?? today
        let root = baseURL ?? tool.logDirectoryURL

        let buckets: [Date: UsageBucket]
        if let root, fileManager.fileExists(atPath: root.path) {
            switch tool {
            case .claude:
                buckets = claudeBuckets(in: root, since: since)
            case .codex:
                buckets = codexBuckets(in: root, since: since)
            }
        } else {
            buckets = [:]
        }

        let todayBucket = buckets[today] ?? UsageBucket()
        let yesterdayBucket = buckets[yesterday] ?? UsageBucket()
        let last30Bucket = buckets
            .filter { $0.key >= since && $0.key <= today }
            .reduce(into: UsageBucket()) { aggregate, entry in
                aggregate.add(tokens: entry.value.tokens, cost: entry.value.costUSD)
            }

        return TokenUsageSummary(
            fetchedAt: now,
            source: tool == .claude ? "Claude local usage" : "Codex local usage",
            today: TokenUsageDay(date: today, totalTokens: todayBucket.tokens, costUSD: todayBucket.costUSD ?? 0),
            yesterday: TokenUsageDay(date: yesterday, totalTokens: yesterdayBucket.tokens, costUSD: yesterdayBucket.costUSD ?? 0),
            last30Days: TokenUsageDay(date: since, totalTokens: last30Bucket.tokens, costUSD: last30Bucket.costUSD ?? 0)
        )
    }

    private func claudeBuckets(in root: URL, since: Date) -> [Date: UsageBucket] {
        var recordsByID: [String: UsageRecord] = [:]
        enumerateJSONL(in: root, since: since) { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            for (index, line) in lines.enumerated() {
                guard let object = jsonObject(String(line)),
                      let date = date(from: object),
                      date >= since,
                      let record = claudeRecord(from: object, date: date) else { continue }
                let id = claudeIdentity(from: object) ?? "\(url.path)#\(index)"
                if let existing = recordsByID[id], existing.totalTokens >= record.totalTokens { continue }
                recordsByID[id] = record
            }
        }
        return buckets(from: Array(recordsByID.values), pricing: claudeCost)
    }

    private func codexBuckets(in root: URL, since: Date) -> [Date: UsageBucket] {
        var records: [UsageRecord] = []
        enumerateJSONL(in: root, since: since) { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            var currentModel: String?
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            for line in lines {
                guard let object = jsonObject(String(line)) else { continue }
                currentModel = model(from: object) ?? currentModel
                guard let date = date(from: object),
                      date >= since,
                      let record = codexRecord(from: object, date: date, model: currentModel) else { continue }
                records.append(record)
            }
        }
        return buckets(from: records, pricing: codexCost)
    }

    private func buckets(
        from records: [UsageRecord],
        pricing: (UsageRecord) -> Double?
    ) -> [Date: UsageBucket] {
        records.reduce(into: [Date: UsageBucket]()) { buckets, record in
            let day = calendar.startOfDay(for: record.date)
            let cost = record.explicitCostUSD ?? pricing(record)
            buckets[day, default: UsageBucket()].add(tokens: record.totalTokens, cost: cost)
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
        let rates = claudeRates(for: record.model)
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
        guard let rates = codexRates(for: record.model) else { return nil }
        let cached = min(record.cachedInputTokens, record.inputTokens)
        let uncached = max(0, record.inputTokens - cached)
        let cachedRate = rates.cacheReadExplicit ? rates.cacheRead : rates.input
        return ((Double(uncached) * rates.input)
            + (Double(cached) * cachedRate)
            + (Double(record.outputTokens) * rates.output)) / 1_000_000
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
            + (Double(cacheCreationFiveMinuteTokens) * rates.cacheWrite)
            + (Double(cacheCreationOneHourTokens) * rates.cacheWrite)
            + (Double(cacheReadTokens) * rates.cacheRead)
            + (Double(outputTokens) * rates.output)) / 1_000_000
    }

    private func claudeRates(for model: String?) -> ModelRates {
        let text = model?.lowercased() ?? ""
        if text.contains("fable-5") {
            return ModelRates(input: 10.0, cacheWrite: 12.5, cacheRead: 1.0, output: 50.0, cacheReadExplicit: true)
        }
        if text.contains("opus") {
            if usesModernOpusPricing(text) {
                return ModelRates(input: 5.0, cacheWrite: 6.25, cacheRead: 0.50, output: 25.0, cacheReadExplicit: true)
            }
            return ModelRates(input: 15.0, cacheWrite: 18.75, cacheRead: 1.50, output: 75.0, cacheReadExplicit: true)
        }
        if text.contains("haiku") {
            if text.contains("3-5") || text.contains("3.5") {
                return ModelRates(input: 0.80, cacheWrite: 1.0, cacheRead: 0.08, output: 4.0, cacheReadExplicit: true)
            }
            if text.contains("claude-3-haiku") || text.contains("haiku-3") {
                return ModelRates(input: 0.25, cacheWrite: 0.30, cacheRead: 0.03, output: 1.25, cacheReadExplicit: true)
            }
            return ModelRates(input: 1.0, cacheWrite: 1.25, cacheRead: 0.10, output: 5.0, cacheReadExplicit: true)
        }
        return ModelRates(input: 3.0, cacheWrite: 3.75, cacheRead: 0.30, output: 15.0, cacheReadExplicit: true)
    }

    private func codexRates(for model: String?) -> ModelRates? {
        guard let model, !model.isEmpty else { return nil }
        let text = model.lowercased()
        switch text {
        case "gpt-5.5":
            return ModelRates(input: 5.0, cacheWrite: 5.0, cacheRead: 0.50, output: 30.0, cacheReadExplicit: true)
        case "gpt-5.4":
            return ModelRates(input: 2.5, cacheWrite: 2.5, cacheRead: 0.25, output: 15.0, cacheReadExplicit: true)
        case "gpt-5.4-mini":
            return ModelRates(input: 0.75, cacheWrite: 0.75, cacheRead: 0.075, output: 4.5, cacheReadExplicit: true)
        case "gpt-5.4-nano":
            return ModelRates(input: 0.20, cacheWrite: 0.20, cacheRead: 0.020, output: 1.25, cacheReadExplicit: true)
        case "gpt-5.3-codex", "gpt-5.3-spark", "gpt-5.3-codex-spark", "gpt-5.2", "gpt-5.2-codex":
            return ModelRates(input: 1.75, cacheWrite: 1.75, cacheRead: 0.175, output: 14.0, cacheReadExplicit: true)
        case "gpt-5", "gpt-5.1", "gpt-5.1-codex":
            return ModelRates(input: 1.25, cacheWrite: 1.25, cacheRead: 0.125, output: 10.0, cacheReadExplicit: true)
        case "gpt-5-mini", "gpt-5.1-codex-mini":
            return ModelRates(input: 0.25, cacheWrite: 0.25, cacheRead: 0.025, output: 2.0, cacheReadExplicit: true)
        case "gpt-5-nano":
            return ModelRates(input: 0.05, cacheWrite: 0.05, cacheRead: 0.005, output: 0.40, cacheReadExplicit: true)
        default:
            return nil
        }
    }

    private func usesModernOpusPricing(_ model: String) -> Bool {
        ["4-5", "4.5", "4_5", "4-6", "4.6", "4_6", "4-7", "4.7", "4_7", "4-8", "4.8", "4_8", "latest"]
            .contains { model.contains($0) }
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

    private func enumerateJSONL(in directory: URL, since: Date, handler: (URL) -> Void) {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var count = 0
        for case let url as URL in enumerator {
            count += 1
            if count > 50_000 { break }
            guard url.pathExtension == "jsonl" else { continue }
            if let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               mtime < since {
                continue
            }
            handler(url)
        }
    }

    private func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
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
