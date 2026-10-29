import Combine
import Foundation

struct WarmupLog: Identifiable {
    let id = UUID()
    let timestamp: Date
    let mode: String
    let command: String
    let output: String
}

// MARK: - ToolState

@MainActor
final class ToolState: ObservableObject {
    /// The watched account. A `var` only so a rename can update its label;
    /// identity (kind + account id) never changes.
    var tool: ProviderID

    /// Source of truth for how this tool is treated. `.monitor` is the safe
    /// default; `.autoWarm` is an explicit opt-in. See `ToolMode`.
    @Published var mode: ToolMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: AppSettings.Key.toolMode(tool.rawValue)) }
    }

    /// Whether QuotaWarmer polls quota for this tool (monitor or auto-warm).
    var isMonitored: Bool { mode != .off }
    /// Whether automatic warm-up may fire for this tool.
    var isAutoWarmEnabled: Bool { mode == .autoWarm }

    /// Whether this tool's glyph + quota is pinned to the menu bar. Independent
    /// of `mode` — an off/monitor tool can still be watched in the menu bar.
    @Published var menuBarVisible: Bool {
        didSet { UserDefaults.standard.set(menuBarVisible, forKey: AppSettings.Key.menuBarVisible(tool.rawValue)) }
    }
    /// Show quota as remaining (drains to 0%) or used (fills to 100%). Affects
    /// only the bars, row text and menu-bar percent — never warm-up decisions.
    @Published var displayMode: QuotaDisplayMode {
        didSet { UserDefaults.standard.set(displayMode.rawValue, forKey: QuotaDisplayMode.defaultsKey(storageKey: tool.storageKey)) }
    }
    @Published var isFetchingQuota = false
    @Published var isWarming = false
    @Published var errorMessage: String?
    @Published var quotaSnapshot: QuotaSnapshot?
    @Published var tokenUsageSummary: TokenUsageSummary?
    @Published var isFetchingTokenUsage = false
    @Published var sourceHealth: SourceHealth = .unknown
    /// The last fetch found Claude's access token expired; only the CLI can
    /// refresh it. Cleared by the next successful fetch.
    var awaitingCLITokenRefresh = false
    /// When QuotaWarmer last ran the CLI's quota-free token refresh (throttle).
    var lastCLITokenRefreshAttemptAt: Date?
    @Published var authStatus: AuthStatus = .unknown
    @Published var healthMessage: String = "not checked"
    @Published var nextRefreshAt: Date?
    @Published var backoffUntil: Date?
    @Published var quotaBackoffUntil: Date?
    @Published var authRetryScheduledAt: Date?
    @Published var confirmedWarmupResetAt: Date?
    @Published var lastAutoWindowKey: String?
    /// When the window we last auto-warmed will reset. Until then, the auto path
    /// won't warm again — a dedup that survives providers whose reported reset
    /// time drifts between polls (e.g. Codex `reset_after_seconds`).
    @Published var lastAutoWarmWindowEndsAt: Date?
    /// Why the last automatic or morning warm-up evaluation didn't warm; nil
    /// after one that did (or before any ran). Display-only.
    @Published private(set) var lastAutoWarmSkip: AutoWarmSkipReason?
    /// When that evaluation ran (display-only, for the status line).
    @Published private(set) var lastAutoWarmDecisionAt: Date?
    @Published var lastWarmupOutcome: WarmupOutcome = .none
    /// Model the last warm-up command used (for the persisted event log).
    var lastWarmupModel: String?
    @Published var warmupLogs: [WarmupLog] = []
    @Published var isLogExpanded = false
    var quotaBackoffDelay: TimeInterval = 0
    var authRetryAttempts = 0
    var authRetryTask: Task<Void, Never>?
    var claimVerifyTask: Task<Void, Never>?
    var settleRepollTask: Task<Void, Never>?

    /// A stand-in for a removed account: off, nothing restored or saved.
    init(orphan tool: ProviderID) {
        self.tool = tool
        self.mode = .off
        self.menuBarVisible = false
        self.displayMode = .remaining
    }

    init(tool: ProviderID) {
        self.tool = tool
        self.mode = ToolState.resolveMode(for: tool)
        self.menuBarVisible = UserDefaults.standard.object(forKey: AppSettings.Key.menuBarVisible(tool.rawValue)) as? Bool ?? true
        self.displayMode = QuotaDisplayMode.stored(storageKey: tool.storageKey)
        self.lastAutoWindowKey = UserDefaults.standard.string(forKey: AppSettings.Key.lastAutoWindowKey(tool.rawValue))
        if let storedEnds = UserDefaults.standard.object(forKey: AppSettings.Key.lastAutoWarmEndsAt(tool.rawValue)) as? TimeInterval {
            let endsAt = Date(timeIntervalSince1970: storedEnds)
            if endsAt > Date() {
                self.lastAutoWarmWindowEndsAt = endsAt
            } else {
                UserDefaults.standard.removeObject(forKey: AppSettings.Key.lastAutoWarmEndsAt(tool.rawValue))
            }
        }
        if let storedReset = UserDefaults.standard.object(forKey: AppSettings.Key.confirmedWarmupResetAt(tool.rawValue)) as? TimeInterval {
            let resetAt = Date(timeIntervalSince1970: storedReset)
            if resetAt > Date() {
                self.confirmedWarmupResetAt = resetAt
            } else {
                UserDefaults.standard.removeObject(forKey: AppSettings.Key.confirmedWarmupResetAt(tool.rawValue))
            }
        }
    }

    /// Resolves the persisted mode, migrating older installs. A previously
    /// "active" tool keeps auto-warm; a previously "passive" tool stays off;
    /// brand-new installs default to monitor-only (safe, read-only).
    private static func resolveMode(for tool: ProviderID) -> ToolMode {
        let key = AppSettings.Key.toolMode(tool.rawValue)
        if let raw = UserDefaults.standard.string(forKey: key), let stored = ToolMode(rawValue: raw) {
            return stored
        }
        if let legacyActive = UserDefaults.standard.object(forKey: AppSettings.Key.toolActiveLegacy(tool.rawValue)) as? Bool {
            let migrated: ToolMode = legacyActive ? .autoWarm : .off
            UserDefaults.standard.set(migrated.rawValue, forKey: key)
            return migrated
        }
        UserDefaults.standard.set(ToolMode.monitor.rawValue, forKey: key)
        return .monitor
    }

    var freshness: QuotaFreshness {
        quotaSnapshot?.freshness() ?? .unknown
    }

    var lastSuccessfulFetch: Date? {
        quotaSnapshot?.fetchedAt
    }

    var primaryMetric: QuotaMetric? {
        quotaSnapshot?.fiveHour
    }

    var weeklyMetric: QuotaMetric? {
        quotaSnapshot?.weekly
    }

    var credentialSource: String? {
        quotaSnapshot?.message
    }

    var resetAt: Date? {
        // A real (non-idle) live reset is authoritative.
        if let metric = primaryMetric, !metric.isIdle, let liveReset = metric.resetAt {
            return liveReset
        }
        // Otherwise a just-confirmed warm-up's known boundary beats an idle
        // "if you started now" projection (which slides on every poll).
        if let confirmedWarmupResetAt, confirmedWarmupResetAt > Date() {
            return confirmedWarmupResetAt
        }
        // Fall back to the idle projection (or nil) so the UI still shows a
        // countdown when no window has been claimed.
        return primaryMetric?.resetAt
    }

    /// The reset of a *real* (live or just-claimed) window, excluding the idle
    /// "if you started now" projection. `resetAt` deliberately falls back to that
    /// sliding projection so the UI shows a countdown for idle windows — but a
    /// projection is not a window that will actually expire, so anything that
    /// schedules a real-world action off the reset (e.g. the "window expiring
    /// soon" notification) must use this instead to avoid alarming the user about
    /// an idle window that never opened.
    var realWindowResetAt: Date? {
        if let metric = primaryMetric, !metric.isIdle, let liveReset = metric.resetAt {
            return liveReset
        }
        if let confirmedWarmupResetAt, confirmedWarmupResetAt > Date() {
            return confirmedWarmupResetAt
        }
        return nil
    }

    var timeUntilReset: TimeInterval? {
        guard let resetAt else { return nil }
        let remaining = resetAt.timeIntervalSinceNow
        return remaining > 0 ? remaining : nil
    }

    /// The last known 5h window's reset moment has already passed, so that
    /// window rolled over and the snapshot's usage figures describe a window
    /// that no longer exists. Reached when live polling is blocked (rate limit,
    /// auth) for longer than the window itself — continuing to show the old
    /// percentage would claim the user has far less quota than they really do.
    ///
    /// Note this is *not* the same as a stale-but-still-valid snapshot: while
    /// the known reset is still in the future its numbers remain correct, which
    /// is why the menu bar keeps counting down even when the dot is yellow.
    var primaryWindowRolledOver: Bool {
        quotaSnapshot?.primaryWindowRolledOver() ?? false
    }

    var windowProgress: Double {
        primaryMetric?.remainingFraction ?? 0
    }

    /// The live 5h reading is a not-yet-settled rollover artifact (window just
    /// opened but reports near-empty quota). Views show a neutral "settling"
    /// state instead of an alarming 0% until a follow-up poll lands the real
    /// number; `scheduleSettleRepoll` drives that poll.
    var sessionSettling: Bool {
        quotaSnapshot?.isUnsettledRolloverReading(windowDuration: tool.windowDuration) ?? false
    }

    var quotaBackoffActive: Bool {
        quotaBackoffUntil.map { $0 > Date() } ?? false
    }

    /// Stores the decision and returns the previous skip reason (nil if it warmed
    /// or none ran) so the caller can record a history event on a change.
    @discardableResult
    func recordAutoWarmDecision(_ decision: AutoWarmDecision) -> AutoWarmSkipReason? {
        let reason = decision.skipReason
        let previous = lastAutoWarmSkip
        if lastAutoWarmSkip != reason { lastAutoWarmSkip = reason }
        lastAutoWarmDecisionAt = Date()
        return previous
    }

    func rememberAutoWindow(_ key: String) {
        lastAutoWindowKey = key
        UserDefaults.standard.set(key, forKey: AppSettings.Key.lastAutoWindowKey(tool.rawValue))
    }

    /// Records when the window we just warmed will reset, so the auto path won't
    /// warm it again until it has ended.
    func rememberAutoWarmWindowEnd(_ date: Date) {
        guard date > Date() else { return }
        lastAutoWarmWindowEndsAt = date
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: AppSettings.Key.lastAutoWarmEndsAt(tool.rawValue))
    }

    func rememberConfirmedWarmup(startedAt: Date, duration: TimeInterval) {
        let resetAt = startedAt.addingTimeInterval(duration)
        guard resetAt > Date() else { return }
        confirmedWarmupResetAt = resetAt
        UserDefaults.standard.set(resetAt.timeIntervalSince1970, forKey: AppSettings.Key.confirmedWarmupResetAt(tool.rawValue))
    }

    func clearConfirmedWarmupIfLiveResetExistsOrExpired(now: Date = Date()) {
        // Only a *real* (non-idle) live reset supersedes the recorded warm-up
        // reset — an idle projection (sliding "if you started now") is not proof
        // a window opened, so it must not clear the confirmed boundary.
        let hasRealLiveReset = primaryMetric?.resetAt != nil && primaryMetric?.isIdle != true
        if hasRealLiveReset || (confirmedWarmupResetAt.map { $0 <= now } ?? false) {
            confirmedWarmupResetAt = nil
            UserDefaults.standard.removeObject(forKey: AppSettings.Key.confirmedWarmupResetAt(tool.rawValue))
        }
    }
}
