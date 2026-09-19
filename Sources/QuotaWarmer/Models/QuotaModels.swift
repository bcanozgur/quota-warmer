import Foundation

enum QuotaFreshness: String {
    case unknown
    case fresh
    case stale
    case expired

    var label: String {
        switch self {
        case .unknown: return "unknown"
        case .fresh: return "fresh"
        case .stale: return "stale"
        case .expired: return "expired"
        }
    }
}

enum SourceHealth: String {
    case unknown
    case healthy
    case stale
    case unavailable
    case authFailure
    case rateLimited

    var label: String {
        switch self {
        case .unknown: return "unknown"
        case .healthy: return "healthy"
        case .stale: return "stale"
        case .unavailable: return "unavailable"
        case .authFailure: return "auth failure"
        case .rateLimited: return "rate limited"
        }
    }
}

enum AuthStatus: String {
    case unknown
    case available
    case missing
    case failed

    var label: String {
        switch self {
        case .unknown: return "unknown"
        case .available: return "available"
        case .missing: return "missing"
        case .failed: return "failed"
        }
    }
}

enum HistoryKind: String {
    case quotaFetch
    case resetDetected
    case autoWarmup
    case manualWarmup
    case authFailure
    case rateLimit
    case pollingError
    case updateCheck
}

enum ScheduledWarmupSkipReason: String {
    case alreadySucceeded
    case beforeScheduledTime
    case outsideCatchUpHorizon
    case activeWindowInProgress
    case quotaSourceUnavailable
}

enum ScheduledWarmupDecision {
    case run(caughtUp: Bool)
    case skip(ScheduledWarmupSkipReason)

    var shouldRun: Bool {
        if case .run = self { return true }
        return false
    }

    var caughtUp: Bool {
        if case .run(let caughtUp) = self { return caughtUp }
        return false
    }
}

struct MorningWarmupPolicy {
    static let catchUpLatenessThreshold: TimeInterval = 15 * 60

    static func resolvedLastSuccessfulDay(
        perToolDay: String?,
        legacyDay: String?,
        currentDay: String
    ) -> String? {
        if let perToolDay {
            return perToolDay
        }
        return legacyDay == currentDay ? legacyDay : nil
    }

    static func decision(
        now: Date,
        scheduledAt: Date,
        dayKey: String,
        lastSuccessfulDay: String?,
        liveWindowActive: Bool,
        sourceFresh: Bool,
        windowDuration: TimeInterval,
        catchUpHorizon: TimeInterval? = nil,
        catchUpLatenessThreshold: TimeInterval = Self.catchUpLatenessThreshold
    ) -> ScheduledWarmupDecision {
        if lastSuccessfulDay == dayKey {
            return .skip(.alreadySucceeded)
        }

        let lateness = now.timeIntervalSince(scheduledAt)
        guard lateness >= 0 else {
            return .skip(.beforeScheduledTime)
        }

        let horizon = catchUpHorizon ?? windowDuration
        guard lateness <= horizon else {
            return .skip(.outsideCatchUpHorizon)
        }

        guard sourceFresh else {
            return .skip(.quotaSourceUnavailable)
        }

        if liveWindowActive {
            return .skip(.activeWindowInProgress)
        }

        return .run(caughtUp: lateness > catchUpLatenessThreshold)
    }

    /// Reserves the last full quota-window interval before the requested morning
    /// time. General auto-warm must not claim a window in this interval, or a
    /// 03:50 reset can consume the window that the user explicitly asked to start
    /// at 06:00.
    static func reservesAutomaticWarmup(
        now: Date,
        scheduledAt: Date,
        windowDuration: TimeInterval
    ) -> Bool {
        now < scheduledAt && now >= scheduledAt.addingTimeInterval(-windowDuration)
    }
}

/// Decides whether the auto path should claim (warm) a fresh window, given the
/// dedup state from the last successful warm. Two independent guards:
///
///  1. Never warm the exact same window key twice.
///  2. Never warm again while a window we already warmed hasn't reset yet — this
///     survives providers whose reported reset time drifts between polls (e.g.
///     Codex `reset_after_seconds`, where `rawWindowKey` changes every poll and
///     would otherwise defeat guard 1).
enum AutoWarmDedup {
    static func shouldWarm(
        currentWindowKey: String,
        lastWarmedWindowKey: String?,
        lastWarmedWindowEndsAt: Date?,
        currentWindowIsIdle: Bool = false,
        now: Date = Date()
    ) -> Bool {
        // An idle (not-yet-started) window carries a *stable*, recurring key (e.g.
        // "…|idle"): every successive idle period shares it, so key equality can't
        // distinguish "already warmed this idle window" from "a brand-new idle
        // window after the last one expired". For idle windows, rely solely on
        // `lastWarmedWindowEndsAt` (the temporal guard) — which blocks re-warming
        // for the just-claimed window's duration and then lets the next idle window
        // through. This also self-heals a stale stored "idle" key from older builds.
        if !currentWindowIsIdle,
           let lastWarmedWindowKey, lastWarmedWindowKey == currentWindowKey { return false }
        if let endsAt = lastWarmedWindowEndsAt, endsAt > now { return false }
        return true
    }
}

struct HistoryEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let tool: ToolID?
    let kind: HistoryKind
    let title: String
    let detail: String
}

/// Result of the most recent warm-up, used to *prove* a window was actually
/// claimed rather than just that a command was sent.
enum WarmupOutcome: Equatable {
    case none
    /// Command sent; verifying the window opened (grace re-check in flight).
    case pending(sentAt: Date)
    /// Verified: the live quota shows an active window.
    case confirmed(at: Date, resetAt: Date?)
    /// The CLI command completed, but the provider did not expose an active
    /// window during the bounded verification period.
    case unverified(sentAt: Date, expectedResetAt: Date?)
    /// The warm-up command itself failed.
    case failed(at: Date, reason: String)
}

struct QuotaMetric: Identifiable {
    let id = UUID()
    let name: String
    let usedPercent: Double
    let remainingPercent: Double?
    let resetAt: Date?
    let detail: String?
    let context: String
    /// The window has not actually started: its quota is full and any `resetAt`
    /// is a sliding "if you started now" projection (Codex's idle 5h window) or
    /// synthesized from Claude's null `five_hour` slot. It is claimable by an
    /// opted-in auto-warm, but must not count as already opened or confirmed.
    let isIdle: Bool

    init(
        name: String,
        usedPercent: Double,
        remainingPercent: Double?,
        resetAt: Date?,
        detail: String?,
        context: String = "",
        isIdle: Bool = false
    ) {
        self.name = name
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
        self.detail = detail
        self.context = context
        self.isIdle = isIdle
    }

    var clampedUsed: Double {
        min(max(usedPercent, 0), 1)
    }

    var remainingFraction: Double {
        if let remainingPercent {
            return min(max(remainingPercent, 0), 1)
        }
        return min(max(1 - clampedUsed, 0), 1)
    }

    var isIdleFiveHourWindow: Bool {
        isIdle && name.lowercased().contains("5h")
    }
}

struct TokenUsageDay: Identifiable, Equatable {
    let date: Date
    let totalTokens: Int
    let costUSD: Double?

    var id: Date { date }
}

struct TokenUsageSummary: Equatable {
    let fetchedAt: Date
    let source: String
    let today: TokenUsageDay
    let yesterday: TokenUsageDay
    let last30Days: TokenUsageDay

    var hasUsage: Bool {
        today.totalTokens > 0 || yesterday.totalTokens > 0 || last30Days.totalTokens > 0
    }
}

struct QuotaSnapshot {
    let tool: ToolID
    let fetchedAt: Date
    let primarySource: String
    let corroboratingSource: String?
    let fiveHour: QuotaMetric?
    let weekly: QuotaMetric?
    let extras: [QuotaMetric]
    let rawWindowKey: String
    let message: String?

    func freshness(now: Date = Date()) -> QuotaFreshness {
        let age = now.timeIntervalSince(fetchedAt)
        if age <= 5 * 60 { return .fresh }
        if age <= 30 * 60 { return .stale }
        return .expired
    }

    func canAutoWarm(
        now: Date = Date(),
        windowDuration: TimeInterval,
        remainingThreshold: Double = 0.95,
        freshWindowGrace: TimeInterval = 10 * 60
    ) -> Bool {
        guard freshness(now: now) == .fresh,
              let metric = fiveHour,
              let resetAt = metric.resetAt,
              metric.remainingFraction >= remainingThreshold else {
            return false
        }
        // An idle window is exactly what auto-warm is meant to claim. Claude's
        // metric is synthesized from a null `five_hour` slot, but sending the
        // warm-up command opens the real window. `AutoWarmDedup` guards the full
        // claimed duration, so the sliding idle projection cannot cause repeats.

        let inferredWindowStart = resetAt.addingTimeInterval(-windowDuration)
        let windowAge = now.timeIntervalSince(inferredWindowStart)
        return windowAge >= 0 && windowAge <= freshWindowGrace
    }

    func isClaimableAutoWindow(previousFetchedAt: Date?, now: Date = Date()) -> Bool {
        guard freshness(now: now) == .fresh else { return false }
        guard let previousFetchedAt else { return true }
        return fetchedAt > previousFetchedAt
    }

    /// True when this (fresh) post-warm snapshot shows an active 5-hour window:
    /// a live reset in the future, or — when the API omits `resetAt` (e.g. the
    /// Codex `wham/usage` payload) — a window that isn't depleted. This is the
    /// signal that a warm-up actually *claimed* the window, not just that the
    /// command exited zero.
    func showsActiveWindow(now: Date = Date()) -> Bool {
        guard freshness(now: now) == .fresh, let metric = fiveHour else { return false }
        // A synthesized *idle* window (no reset, 100% left — Claude's `five_hour`
        // came back null) is the absence of a claimed window, not proof one
        // opened. It must never confirm a warm-up.
        if metric.isIdleFiveHourWindow { return false }
        if let resetAt = metric.resetAt { return resetAt > now }
        return metric.remainingFraction >= 0.5
    }

    /// The 5-hour window this snapshot describes has already reset, so its usage
    /// figures are obsolete. Reached when live polling stays blocked (rate limit,
    /// auth failure) for longer than the window itself. Callers should report the
    /// quota as restored rather than keep showing the pre-reset percentage, which
    /// would understate what the user actually has available.
    ///
    /// Distinct from mere staleness: while the reset is still ahead the numbers
    /// remain accurate, which is why the countdown keeps running even when the
    /// snapshot is stale. An idle window has no real reset to pass.
    func primaryWindowRolledOver(now: Date = Date()) -> Bool {
        guard let metric = fiveHour, !metric.isIdle, let resetAt = metric.resetAt else { return false }
        return resetAt <= now
    }

    /// True when the 5-hour window's reset says it only *just* opened (almost the
    /// whole window still remains) yet the reported quota is implausibly low.
    /// Right at a window rollover Claude's OAuth usage API briefly returns the
    /// just-ended window's high utilization paired with the *new* window's reset
    /// time — and a full 5h budget can't be spent in the first few minutes. Treat
    /// such a reading as a not-yet-settled artifact (the UI shows "settling" and
    /// we re-poll soon) rather than alarming the user with "0% left / runs out
    /// in 0s". `idleSettleWindow` is the post-open grace; `depletionFloor` is the
    /// largest fraction that could legitimately be burned that quickly.
    func isUnsettledRolloverReading(
        windowDuration: TimeInterval,
        now: Date = Date(),
        idleSettleWindow: TimeInterval = 5 * 60,
        depletionFloor: Double = 0.5
    ) -> Bool {
        guard freshness(now: now) == .fresh,
              let metric = fiveHour,
              !metric.isIdleFiveHourWindow,
              let resetAt = metric.resetAt else { return false }
        let elapsed = windowDuration - resetAt.timeIntervalSince(now)
        return elapsed >= 0 && elapsed <= idleSettleWindow && metric.remainingFraction <= depletionFloor
    }
}

struct Credential {
    let accessToken: String
    let refreshToken: String?
    let accountID: String?
    let source: String
    let expiresAt: Date?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 60
    }
}

enum CredentialError: LocalizedError {
    case missing(String)
    case invalid(String)
    case interactionRequired(String)

    var errorDescription: String? {
        switch self {
        case .missing(let provider): return "\(provider) credentials not found"
        case .invalid(let provider): return "\(provider) credentials are invalid"
        case .interactionRequired(let provider): return "\(provider) credential access requires approval"
        }
    }
}

enum QuotaProviderError: LocalizedError {
    case missingCredentials(String)
    case credentialInteractionRequired(String)
    /// Claude Code owns refresh-token rotation. Run the CLI, then read its fresh credential.
    case cliRefreshRequired(String)
    case authFailure(String)
    case rateLimited(String, retryAfter: TimeInterval?)
    case unavailable(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials(let msg): return msg
        case .credentialInteractionRequired(let msg): return msg
        case .cliRefreshRequired(let msg): return msg
        case .authFailure(let msg): return msg
        case .rateLimited(let msg, _): return msg
        case .unavailable(let msg): return msg
        case .malformed(let msg): return msg
        }
    }
}
