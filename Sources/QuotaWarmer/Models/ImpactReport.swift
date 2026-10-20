import Foundation

/// Time span an Impact report covers.
enum ImpactRange: String, CaseIterable, Identifiable {
    case week, month, all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .week: return "7d"
        case .month: return "30d"
        case .all: return "All"
        }
    }

    /// nil = everything that is stored.
    var interval: TimeInterval? {
        switch self {
        case .week: return 7 * 24 * 3600
        case .month: return 30 * 24 * 3600
        case .all: return nil
        }
    }

    func start(now: Date) -> Date {
        interval.map { now.addingTimeInterval(-$0) } ?? .distantPast
    }
}

/// Everything the report needs for one account. The caller loads these from
/// `EventLogStore`, `UsageHistoryStore` and the account's local-usage summary.
struct ImpactInput {
    let provider: ProviderID
    let events: [HistoryEvent]
    let samples: [QuotaSample]
    let hourly: [TokenUsageHour]
    let windowDuration: TimeInterval
}

/// Rough size of one warm-up call, used only for the cost estimate. The CLI
/// sends its system prompt plus `hi` and gets a one-line reply.
struct WarmupCostEstimate: Equatable {
    var inputTokens: Int = 15_000
    var outputTokens: Int = 100

    func cost(of model: ModelCatalog.Model) -> Double {
        (Double(inputTokens) * model.input + Double(outputTokens) * model.output) / 1_000_000
    }
}

/// Claimed-window counts, split by what triggered the warm-up.
struct ImpactClaims: Equatable {
    var auto = 0
    var morning = 0
    var manual = 0
    var intent = 0
    /// Confirmed windows whose warm-up could not be traced (older log lines).
    var unattributed = 0
    var missed = 0
    var failed = 0

    var claimed: Int { auto + morning + manual + intent + unattributed }
    var attempts: Int { claimed + missed + failed }
    /// nil until at least one warm-up has resolved.
    var successRate: Double? { attempts == 0 ? nil : Double(claimed) / Double(attempts) }
}

struct ImpactHeadStart: Equatable {
    /// Claimed windows whose first real usage is known.
    var measuredWindows = 0
    /// Claimed windows that ended with no usage at all.
    var unusedWindows = 0
    var total: TimeInterval = 0
    var average: TimeInterval? { measuredWindows == 0 ? nil : total / Double(measuredWindows) }
}

struct ImpactCost: Equatable {
    var warmups = 0
    var pricedWarmups = 0
    var usd = 0.0

    var unpricedWarmups: Int { warmups - pricedWarmups }

    /// Never "$0.00" for something we could not price.
    var displayText: String {
        if warmups == 0 { return "–" }
        if pricedWarmups == 0 { return "unpriced" }
        let amount = usd < 0.01 ? "<$0.01" : String(format: "$%.2f", usd)
        return unpricedWarmups > 0 ? amount + "+" : amount
    }
}

struct ImpactUtilization: Equatable {
    var windows = 0
    /// Windows whose peak reached `ImpactReport.highUseThreshold`.
    var highUseWindows = 0
    var weeks = 0
    var weeksAtLimit = 0

    var highUseShare: Double? { windows == 0 ? nil : Double(highUseWindows) / Double(windows) }
}

struct ImpactBucket: Identifiable, Equatable {
    let start: Date
    var auto = 0
    var morning = 0
    var manual = 0
    var other = 0
    var id: Date { start }
    var total: Int { auto + morning + manual + other }
}

struct ImpactReport: Equatable {
    static let highUseThreshold = 0.80
    static let weeklyLimitThreshold = 0.95
    /// A claimed window's first bucket of at most this many tokens is taken
    /// to be the warm-up itself, not the user.
    static let warmupNoiseTokens = 30_000

    let range: ImpactRange
    let claims: ImpactClaims
    let headStart: ImpactHeadStart
    let cost: ImpactCost
    let utilization: ImpactUtilization
    let buckets: [ImpactBucket]
    /// True when nothing has been claimed yet, so the UI shows its empty state.
    var isEmpty: Bool { claims.attempts == 0 && cost.warmups == 0 }

    static func make(
        inputs: [ImpactInput],
        range: ImpactRange,
        now: Date,
        calendar: Calendar = .current,
        estimate: WarmupCostEstimate = WarmupCostEstimate(),
        price: (ToolID, String?) -> ModelCatalog.Model?
    ) -> ImpactReport {
        let since = range.start(now: now)
        var claims = ImpactClaims()
        var head = ImpactHeadStart()
        var cost = ImpactCost()
        var util = ImpactUtilization()
        var bucketCounts: [Date: ImpactBucket] = [:]
        var weekKeys: [String: Bool] = [:]
        let bucketUnit: Calendar.Component = range == .all ? .weekOfYear : .day

        for input in inputs {
            let events = input.events
                .filter { $0.tool?.storageKey == input.provider.storageKey }
                .sorted { $0.timestamp < $1.timestamp }
            let duration = input.windowDuration
            let sent = events.filter { $0.outcome == .sent && isWarmup($0) }

            // Cost: every warm-up that was sent, claimed or not.
            for event in sent where event.timestamp >= since && event.timestamp <= now {
                cost.warmups += 1
                if let model = price(input.provider.kind, event.model) {
                    cost.pricedWarmups += 1
                    cost.usd += estimate.cost(of: model)
                }
            }

            // Claims: one per distinct window, however many receipts it got.
            var seenWindows = Set<String>()
            for event in events where event.outcome == .confirmed {
                guard event.timestamp >= since, event.timestamp <= now else { continue }
                let identity = event.windowKey
                    ?? event.windowResetAt.map { "reset-\(Int($0.timeIntervalSince1970 / 600))" }
                    ?? event.id.uuidString
                guard seenWindows.insert(identity).inserted else { continue }
                let origin = sent.last { $0.timestamp <= event.timestamp
                    && event.timestamp.timeIntervalSince($0.timestamp) <= duration }
                let source = event.source ?? origin?.source
                switch source {
                case .auto: claims.auto += 1
                case .morning: claims.morning += 1
                case .manual: claims.manual += 1
                case .intent: claims.intent += 1
                case nil: claims.unattributed += 1
                }
                bump(&bucketCounts, event.timestamp, source, unit: bucketUnit, calendar: calendar)

                // Head start: window start → first real usage, capped.
                let reset = event.windowResetAt ?? event.timestamp.addingTimeInterval(duration)
                let windowStart = reset.addingTimeInterval(-duration)
                let windowEnd = reset
                let anchor = origin?.timestamp ?? windowStart
                let firstUse = firstUsage(
                    in: input.hourly, from: windowStart, to: windowEnd, warmupAt: anchor, calendar: calendar)
                if let firstUse {
                    head.measuredWindows += 1
                    head.total += min(max(firstUse.timeIntervalSince(windowStart), 0), duration)
                } else if windowEnd <= now {
                    head.unusedWindows += 1
                }
            }

            // Misses: a miss later healed into a confirmation is not a miss.
            for (index, event) in events.enumerated() where event.outcome == .missed || event.outcome == .failed {
                guard event.timestamp >= since, event.timestamp <= now else { continue }
                if event.outcome == .failed { claims.failed += 1; continue }
                let healed = events[(index + 1)...].contains { later in
                    if later.outcome == .sent { return false }
                    return later.outcome == .confirmed
                        && later.timestamp.timeIntervalSince(event.timestamp) <= duration
                }
                if !healed { claims.missed += 1 }
            }

            // Utilization from observed windows.
            for window in UsageHistory.windows(from: input.samples, duration: duration)
            where window.resetAt >= since && window.startAt <= now {
                util.windows += 1
                if window.peakUsed >= highUseThreshold { util.highUseWindows += 1 }
            }
            for sample in input.samples where sample.t >= since && sample.t <= now {
                guard let weekly = sample.w else { continue }
                let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: sample.t)
                let key = "\(input.provider.storageKey)|\(parts.yearForWeekOfYear ?? 0)-\(parts.weekOfYear ?? 0)"
                weekKeys[key] = (weekKeys[key] ?? false) || weekly >= weeklyLimitThreshold
            }
        }
        util.weeks = weekKeys.count
        util.weeksAtLimit = weekKeys.values.filter { $0 }.count

        return ImpactReport(
            range: range, claims: claims, headStart: head, cost: cost, utilization: util,
            buckets: filledBuckets(bucketCounts, range: range, now: now, unit: bucketUnit, calendar: calendar))
    }

    // MARK: - Helpers

    private static func isWarmup(_ event: HistoryEvent) -> Bool {
        event.kind == .autoWarmup || event.kind == .manualWarmup
    }

    /// First moment of real usage in `[start, end)`, or nil. Hourly buckets
    /// only say "sometime in this hour", so a bucket yields `max(hour, start)`.
    /// The bucket holding the warm-up is skipped when it is just the warm-up.
    static func firstUsage(
        in hourly: [TokenUsageHour], from start: Date, to end: Date, warmupAt: Date, calendar: Calendar
    ) -> Date? {
        let warmupHour = calendar.dateInterval(of: .hour, for: warmupAt)?.start
        for entry in hourly.sorted(by: { $0.hour < $1.hour }) where entry.tokens > 0 {
            let bucketEnd = entry.hour.addingTimeInterval(3600)
            guard bucketEnd > start, entry.hour < end else { continue }
            if entry.hour == warmupHour, entry.tokens <= warmupNoiseTokens { continue }
            return max(entry.hour, start)
        }
        return nil
    }

    private static func bump(
        _ buckets: inout [Date: ImpactBucket], _ date: Date, _ source: WarmupSource?,
        unit: Calendar.Component, calendar: Calendar
    ) {
        guard let start = bucketStart(date, unit: unit, calendar: calendar) else { return }
        var bucket = buckets[start] ?? ImpactBucket(start: start)
        switch source {
        case .auto: bucket.auto += 1
        case .morning: bucket.morning += 1
        case .manual: bucket.manual += 1
        default: bucket.other += 1
        }
        buckets[start] = bucket
    }

    private static func bucketStart(_ date: Date, unit: Calendar.Component, calendar: Calendar) -> Date? {
        unit == .day ? calendar.startOfDay(for: date) : calendar.dateInterval(of: .weekOfYear, for: date)?.start
    }

    /// Empty periods included, so the chart's x-axis is continuous.
    private static func filledBuckets(
        _ counts: [Date: ImpactBucket], range: ImpactRange, now: Date, unit: Calendar.Component, calendar: Calendar
    ) -> [ImpactBucket] {
        guard let last = bucketStart(now, unit: unit, calendar: calendar) else { return [] }
        let first: Date
        if let days = range.interval.map({ Int($0 / 86_400) }) {
            first = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)) ?? last
        } else {
            guard let earliest = counts.keys.min() else { return [] }
            first = earliest
        }
        var result: [ImpactBucket] = []
        var cursor = first
        while cursor <= last, result.count < 400 {
            result.append(counts[cursor] ?? ImpactBucket(start: cursor))
            guard let next = calendar.date(byAdding: unit, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }
}
