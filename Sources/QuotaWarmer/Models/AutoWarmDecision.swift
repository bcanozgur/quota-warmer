import Foundation

/// Why an automatic (or scheduled morning) warm-up did not fire. Recorded per
/// tool on `ToolState.lastAutoWarmSkip` so the UI can explain "why didn't it warm".
enum AutoWarmSkipReason: Equatable {
    /// The tool is off or monitor-only; auto-warm is not opted in.
    case autoWarmOff
    /// Global pause (`globalPassive`) is on.
    case paused
    /// A warm-up for this tool is already running.
    case warmupInProgress
    /// Credentials are missing or the CLI rejected them.
    case authUnavailable(AuthStatus)
    /// A failed warm-up's backoff is active and the rate-limit guard is on.
    case backoff(until: Date)
    /// The quota source is not healthy (stale, rate limited, auth failure…).
    case sourceUnhealthy(SourceHealth)
    /// No quota snapshot, or it has no 5h metric with a reset time.
    case noQuotaReading
    /// The snapshot is older than the fresh threshold.
    case snapshotNotFresh(QuotaFreshness)
    /// Less than the claimable share of the window is left.
    case windowInUse(remaining: Double)
    /// The window opened longer ago than the fresh-window grace.
    case windowNotJustOpened
    /// The interval before the morning pre-warm is reserved for it.
    case reservedForMorning(at: Date)
    /// This exact window key was already auto-warmed.
    case alreadyWarmedWindow
    /// A window we warmed has not reset yet.
    case warmedWindowActive(until: Date)
    /// The scheduled morning pre-warm declined to run.
    case morning(ScheduledWarmupSkipReason)

    var label: String {
        switch self {
        case .autoWarmOff: return "auto-warm is off"
        case .paused: return "paused"
        case .warmupInProgress: return "a warm-up is already running"
        case .authUnavailable(let status): return "sign-in \(status.label)"
        case .backoff: return "backing off after a failed warm-up"
        case .sourceUnhealthy(let health): return "quota source \(health.label)"
        case .noQuotaReading: return "no 5h quota reading"
        case .snapshotNotFresh(let freshness): return "quota reading \(freshness.label)"
        case .windowInUse(let remaining): return "window in use (\(Int((remaining * 100).rounded()))% left)"
        case .windowNotJustOpened: return "window already running"
        case .reservedForMorning: return "reserved for morning pre-warm"
        case .alreadyWarmedWindow: return "this window was already warmed"
        case .warmedWindowActive: return "warmed window still open"
        case .morning(let reason): return "morning pre-warm: \(reason.rawValue)"
        }
    }
}

/// The pure auto-warm gating rules. `AppState` gathers the inputs and acts on
/// the result; nothing here reads the clock, `UserDefaults` or the network, so
/// every rule is covered by `scripts/quota-extractor-regression.swift`.
///
/// Evaluation is split in two because `AppState` refreshes quota in between:
/// `gate` is checked before the refresh (it must not cost a request when the
/// tool can't warm anyway), `window` after it.
enum AutoWarmDecision: Equatable {
    case warm
    case skip(AutoWarmSkipReason)

    var skipReason: AutoWarmSkipReason? {
        if case .skip(let reason) = self { return reason }
        return nil
    }

    /// Per-tool and global switches that block any managed (auto or morning)
    /// warm-up, checked before spending a quota request.
    struct Gate {
        var isAutoWarmEnabled: Bool
        var globalPassive: Bool
        var isWarming: Bool
        var authStatus: AuthStatus
        var rateLimitGuard: Bool
        var backoffUntil: Date?
    }

    /// The freshly refreshed quota reading plus the dedup memory of the last
    /// auto-warmed window.
    struct Window {
        var sourceHealth: SourceHealth
        var snapshot: QuotaSnapshot?
        var windowDuration: TimeInterval
        var lastAutoWindowKey: String?
        var lastAutoWarmWindowEndsAt: Date?
        /// Today's morning pre-warm time when it is still ahead (nil when the
        /// pre-warm is off, paused, a skipped weekend, or already past).
        var upcomingMorningAt: Date?
    }

    static func gate(_ gate: Gate, now: Date) -> AutoWarmDecision {
        guard gate.isAutoWarmEnabled else { return .skip(.autoWarmOff) }
        guard !gate.globalPassive else { return .skip(.paused) }
        guard !gate.isWarming else { return .skip(.warmupInProgress) }
        guard gate.authStatus != .failed, gate.authStatus != .missing else {
            return .skip(.authUnavailable(gate.authStatus))
        }
        if gate.rateLimitGuard, let until = gate.backoffUntil, until > now {
            return .skip(.backoff(until: until))
        }
        return .warm
    }

    static func window(_ window: Window, now: Date) -> AutoWarmDecision {
        guard window.sourceHealth == .healthy else { return .skip(.sourceUnhealthy(window.sourceHealth)) }
        guard let snapshot = window.snapshot else { return .skip(.noQuotaReading) }
        guard snapshot.canAutoWarm(now: now, windowDuration: window.windowDuration) else {
            return .skip(notClaimableReason(snapshot, now: now))
        }
        if let morningAt = window.upcomingMorningAt,
           MorningWarmupPolicy.reservesAutomaticWarmup(
               now: now,
               scheduledAt: morningAt,
               windowDuration: window.windowDuration
           ) {
            return .skip(.reservedForMorning(at: morningAt))
        }
        guard AutoWarmDedup.shouldWarm(
            currentWindowKey: snapshot.rawWindowKey,
            lastWarmedWindowKey: window.lastAutoWindowKey,
            lastWarmedWindowEndsAt: window.lastAutoWarmWindowEndsAt,
            currentWindowIsIdle: snapshot.fiveHour?.isIdle == true,
            now: now
        ) else {
            if let endsAt = window.lastAutoWarmWindowEndsAt, endsAt > now {
                return .skip(.warmedWindowActive(until: endsAt))
            }
            return .skip(.alreadyWarmedWindow)
        }
        return .warm
    }

    /// Both stages as one call, for callers (and tests) that have every input.
    static func evaluate(gate: Gate, window: Window, now: Date) -> AutoWarmDecision {
        let gated = Self.gate(gate, now: now)
        guard gated == .warm else { return gated }
        return Self.window(window, now: now)
    }

    /// Explains a `canAutoWarm == false` snapshot. Only called after that check
    /// failed, so it never changes the decision — it just names the guard.
    private static func notClaimableReason(_ snapshot: QuotaSnapshot, now: Date) -> AutoWarmSkipReason {
        let freshness = snapshot.freshness(now: now)
        guard freshness == .fresh else { return .snapshotNotFresh(freshness) }
        guard let metric = snapshot.fiveHour, metric.resetAt != nil else { return .noQuotaReading }
        if metric.remainingFraction < 0.95 { return .windowInUse(remaining: metric.remainingFraction) }
        return .windowNotJustOpened
    }
}
