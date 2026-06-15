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
    let tool: ToolID

    /// Source of truth for how this tool is treated. `.monitor` is the safe
    /// default; `.autoWarm` is an explicit opt-in. See `ToolMode`.
    @Published var mode: ToolMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "toolMode.\(tool.rawValue)") }
    }

    /// Whether QuotaWarmer polls quota for this tool (monitor or auto-warm).
    var isMonitored: Bool { mode != .off }
    /// Whether automatic warm-up may fire for this tool.
    var isAutoWarmEnabled: Bool { mode == .autoWarm }

    /// Whether this tool's glyph + quota is pinned to the menu bar. Independent
    /// of `mode` — an off/monitor tool can still be watched in the menu bar.
    @Published var menuBarVisible: Bool {
        didSet { UserDefaults.standard.set(menuBarVisible, forKey: "menuBarVisible.\(tool.rawValue)") }
    }
    @Published var isFetchingQuota = false
    @Published var isWarming = false
    @Published var errorMessage: String?
    @Published var lastLogActivity: Date?
    @Published var weeklyActivity: [DayActivity] = []
    @Published var quotaSnapshot: QuotaSnapshot?
    @Published var sourceHealth: SourceHealth = .unknown
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
    @Published var lastWarmupOutcome: WarmupOutcome = .none
    @Published var warmupLogs: [WarmupLog] = []
    @Published var isLogExpanded = false
    var quotaBackoffDelay: TimeInterval = 0
    var authRetryAttempts = 0
    var authRetryTask: Task<Void, Never>?
    var claimVerifyTask: Task<Void, Never>?
    var settleRepollTask: Task<Void, Never>?

    init(tool: ToolID) {
        self.tool = tool
        self.mode = ToolState.resolveMode(for: tool)
        self.menuBarVisible = UserDefaults.standard.object(forKey: "menuBarVisible.\(tool.rawValue)") as? Bool ?? true
        self.lastAutoWindowKey = UserDefaults.standard.string(forKey: "lastAutoWindowKey.\(tool.rawValue)")
        if let storedEnds = UserDefaults.standard.object(forKey: "lastAutoWarmEndsAt.\(tool.rawValue)") as? TimeInterval {
            let endsAt = Date(timeIntervalSince1970: storedEnds)
            if endsAt > Date() {
                self.lastAutoWarmWindowEndsAt = endsAt
            } else {
                UserDefaults.standard.removeObject(forKey: "lastAutoWarmEndsAt.\(tool.rawValue)")
            }
        }
        if let storedReset = UserDefaults.standard.object(forKey: "confirmedWarmupResetAt.\(tool.rawValue)") as? TimeInterval {
            let resetAt = Date(timeIntervalSince1970: storedReset)
            if resetAt > Date() {
                self.confirmedWarmupResetAt = resetAt
            } else {
                UserDefaults.standard.removeObject(forKey: "confirmedWarmupResetAt.\(tool.rawValue)")
            }
        }
    }

    /// Resolves the persisted mode, migrating older installs. A previously
    /// "active" tool keeps auto-warm; a previously "passive" tool stays off;
    /// brand-new installs default to monitor-only (safe, read-only).
    private static func resolveMode(for tool: ToolID) -> ToolMode {
        let key = "toolMode.\(tool.rawValue)"
        if let raw = UserDefaults.standard.string(forKey: key), let stored = ToolMode(rawValue: raw) {
            return stored
        }
        if let legacyActive = UserDefaults.standard.object(forKey: "toolActive.\(tool.rawValue)") as? Bool {
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

    var windowProgress: Double {
        primaryMetric?.remainingFraction ?? 0
    }

    var canAutoWarmFromSnapshot: Bool {
        quotaSnapshot?.canAutoWarm(windowDuration: tool.windowDuration) ?? false
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

    func rememberAutoWindow(_ key: String) {
        lastAutoWindowKey = key
        UserDefaults.standard.set(key, forKey: "lastAutoWindowKey.\(tool.rawValue)")
    }

    /// Records when the window we just warmed will reset, so the auto path won't
    /// warm it again until it has ended.
    func rememberAutoWarmWindowEnd(_ date: Date) {
        guard date > Date() else { return }
        lastAutoWarmWindowEndsAt = date
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: "lastAutoWarmEndsAt.\(tool.rawValue)")
    }

    func rememberConfirmedWarmup(startedAt: Date, duration: TimeInterval) {
        let resetAt = startedAt.addingTimeInterval(duration)
        guard resetAt > Date() else { return }
        confirmedWarmupResetAt = resetAt
        UserDefaults.standard.set(resetAt.timeIntervalSince1970, forKey: "confirmedWarmupResetAt.\(tool.rawValue)")
    }

    func clearConfirmedWarmupIfLiveResetExistsOrExpired(now: Date = Date()) {
        // Only a *real* (non-idle) live reset supersedes the recorded warm-up
        // reset — an idle projection (sliding "if you started now") is not proof
        // a window opened, so it must not clear the confirmed boundary.
        let hasRealLiveReset = primaryMetric?.resetAt != nil && primaryMetric?.isIdle != true
        if hasRealLiveReset || (confirmedWarmupResetAt.map { $0 <= now } ?? false) {
            confirmedWarmupResetAt = nil
            UserDefaults.standard.removeObject(forKey: "confirmedWarmupResetAt.\(tool.rawValue)")
        }
    }
}

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {
    @Published var showOnboarding = false
    @Published var isRefreshing = false
    /// Which tab the panel shows. Lifted out of `MenuContent` so the menu-bar
    /// right-click menu ("Show Stats" / "Go to Settings") can drive it.
    @Published var selectedTab: AppTab = .main
    @Published var updateInfo: ReleaseInfo?
    @Published private(set) var toolStates: [ToolID: ToolState]
    @Published var history: [HistoryEvent] = []
    @Published var morningPrewarmEnabled: Bool = UserDefaults.standard.bool(forKey: "morningPrewarmEnabled")
    @Published var morningStatus: String?
    /// Most recent successful quota poll across all tools. Drives the liveness
    /// watchdog so a silently-stalled app stops looking "all good."
    @Published var lastSuccessfulPollAt: Date?
    @Published var globalPassive: Bool {
        didSet {
            UserDefaults.standard.set(globalPassive, forKey: "globalPassive")
            if globalPassive {
                scheduler.invalidateAll()
                ToolID.allCases.forEach { notifications.cancelAll(for: $0) }
            } else {
                refreshAllActivity(allowAutomaticWarmup: true)
            }
        }
    }

    private let scanner = ActivityScanner()
    private let runner = WarmupRunner()
    private let scheduler = Scheduler()
    private let notifications = NotificationManager.shared
    private let updateChecker = UpdateChecker()
    private let quotaProvider: QuotaProviding = QuotaProvider()
    private let wakeScheduler = WakeScheduler()
    private let claudeAuthRetryDelays: [TimeInterval] = [15, 45, 90]
    private var refreshTimer: Timer?
    private var morningTimer: Timer?
    private var morningReapplyTask: Task<Void, Never>?

    init() {
        var states: [ToolID: ToolState] = [:]
        for tool in ToolID.allCases { states[tool] = ToolState(tool: tool) }
        toolStates = states
        globalPassive = UserDefaults.standard.object(forKey: "globalPassive") as? Bool ?? false

        scheduler.onFire = { [weak self] tool in
            Task { @MainActor [weak self] in
                await self?.attemptAutomaticWarmup(tool: tool, reason: "scheduled refresh")
            }
        }
        scheduler.onWake = { [weak self] in
            Task { @MainActor [weak self] in
                // Give polling a grace period after wake so the sleep gap isn't
                // mistaken for a stalled app; the per-tool fires that follow
                // will refresh this on success.
                self?.lastSuccessfulPollAt = Date()
                self?.handleSystemWake()
            }
        }

        refreshAllActivity(allowAutomaticWarmup: false)
        startQuotaRefreshTimer()
        startUIRefreshTimer()
        if morningPrewarmEnabled {
            scheduleMorningTimer()
            Task { await runScheduledMorningWarmupIfNeeded(source: .launch) }
        }
        Task { await checkOnboarding() }
        Task { await checkForAppUpdate() }
    }

    func state(for tool: ToolID) -> ToolState { toolStates[tool]! }

    /// Pins/unpins a tool in the menu bar. Routed through AppState so the
    /// menu-bar label (which observes AppState, not each ToolState) refreshes
    /// immediately when toggled.
    func setMenuBarVisible(_ tool: ToolID, _ visible: Bool) {
        objectWillChange.send()
        state(for: tool).menuBarVisible = visible
    }

    /// Whether anything is being polled right now (drives the watchdog).
    var hasLivePolling: Bool {
        !globalPassive && ToolID.allCases.contains { state(for: $0).isMonitored }
    }

    /// True when the app should be polling but hasn't had a successful quota
    /// fetch in a suspiciously long time — i.e. it may be silently stalled.
    var watcherStale: Bool {
        guard hasLivePolling, let last = lastSuccessfulPollAt else { return false }
        return Date().timeIntervalSince(last) > max(refreshInterval * 2, 120)
    }

    /// User-facing one-liner for the watchdog, or nil when healthy.
    var watcherStatusText: String? {
        guard watcherStale, let last = lastSuccessfulPollAt else { return nil }
        let minutes = max(1, Int(Date().timeIntervalSince(last) / 60))
        return "No successful check in \(minutes)m"
    }

    /// Switches a tool between off / monitor-only / auto-warm. Routed through
    /// AppState (with an explicit objectWillChange) so the menu-bar label —
    /// which observes AppState, not each ToolState — refreshes immediately.
    func setMode(_ mode: ToolMode, for tool: ToolID) {
        let state = state(for: tool)
        guard state.mode != mode else { return }
        objectWillChange.send()
        state.mode = mode

        switch mode {
        case .off:
            scheduler.invalidate(tool: tool)
            notifications.cancelAll(for: tool)
            state.claimVerifyTask?.cancel(); state.claimVerifyTask = nil
            clearAuthRetry(for: state)
            state.nextRefreshAt = nil
            addHistory(tool: tool, kind: .quotaFetch, title: "Monitoring off", detail: "QuotaWarmer will not watch this tool")
        case .monitor:
            addHistory(tool: tool, kind: .quotaFetch, title: "Monitor only", detail: "Watching quota; automatic warm-up off")
            Task { await refreshQuota(for: tool, allowAutomaticWarmup: false) }
        case .autoWarm:
            addHistory(tool: tool, kind: .quotaFetch, title: "Auto-warm on", detail: "Will claim fresh windows automatically")
            Task { await refreshQuota(for: tool, allowAutomaticWarmup: true) }
        }
    }

    func activate(_ tool: ToolID) {
        Task { await triggerWarmup(tool: tool, mode: "manual") }
    }

    func refreshAllActivity(allowAutomaticWarmup: Bool = false, includeInactive: Bool = false) {
        isRefreshing = true
        let tools = ToolID.allCases.filter { includeInactive || state(for: $0).isMonitored }
        guard !tools.isEmpty else {
            isRefreshing = false
            return
        }
        for tool in tools {
            let state = state(for: tool)
            state.lastLogActivity = scanner.lastActivity(for: tool)
            state.weeklyActivity = scanner.weeklyActivity(for: tool)
            Task { await refreshQuota(for: tool, allowAutomaticWarmup: allowAutomaticWarmup) }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            self.isRefreshing = false
        }
    }

    func refreshQuota(for tool: ToolID, allowAutomaticWarmup: Bool = false, reconcileStuckOutcome: Bool = true) async {
        let state = state(for: tool)
        if let backoffUntil = state.quotaBackoffUntil, backoffUntil > Date() {
            state.nextRefreshAt = backoffUntil
            state.errorMessage = rateLimitMessage(until: backoffUntil)
            state.healthMessage = state.errorMessage ?? state.healthMessage
            scheduleQuotaRefresh(for: tool, at: backoffUntil)
            return
        }

        state.isFetchingQuota = true
        state.errorMessage = nil

        do {
            let snapshot = try await quotaProvider.fetchQuota(for: tool)
            clearQuotaBackoff(for: state)
            clearAuthRetry(for: state)
            lastSuccessfulPollAt = Date()
            state.quotaSnapshot = snapshot
            state.sourceHealth = snapshot.freshness() == .fresh ? .healthy : .stale
            state.authStatus = .available
            state.healthMessage = snapshot.message ?? snapshot.primarySource
            state.nextRefreshAt = Date().addingTimeInterval(refreshInterval)
            state.clearConfirmedWarmupIfLiveResetExistsOrExpired()
            // Background self-heal of a stuck warm-up status. Skipped while a
            // warm-up is in flight, and skipped on the recheck path (which calls
            // evaluateWarmupClaim right after) so the two never both confirm.
            if reconcileStuckOutcome, !state.isWarming { reconcileWarmupOutcome(for: state) }
            let cliReady = await applyCLIAuthenticationStatusIfNeeded(for: tool, to: state)
            addHistory(
                tool: tool,
                kind: .quotaFetch,
                title: "Quota fetched",
                detail: quotaFetchDetail(snapshot)
            )
            rescheduleRefresh(for: tool)

            if allowAutomaticWarmup, cliReady {
                await attemptAutomaticWarmup(tool: tool, reason: "fresh quota")
            }
        } catch {
            applyQuotaError(error, to: state)
        }

        state.isFetchingQuota = false
    }

    func applyRefreshInterval() {
        startQuotaRefreshTimer()
        startUIRefreshTimer()
        for tool in ToolID.allCases where state(for: tool).isMonitored {
            state(for: tool).nextRefreshAt = Date().addingTimeInterval(refreshInterval)
        }
    }

    // MARK: - Morning pre-warm

    /// Toggle entry point from Settings. Enabling/disabling touches the system
    /// power schedule via a single admin prompt.
    func setMorningPrewarm(_ enabled: Bool) {
        guard enabled != morningPrewarmEnabled else { return }
        if enabled {
            Task { await enableMorningPrewarm() }
        } else {
            Task { await disableMorningPrewarm() }
        }
    }

    /// Called when the wake time or weekday setting changes. Reschedules the
    /// in-app timer immediately and debounces the hardware re-apply so rapid
    /// stepper edits coalesce into one admin prompt.
    func morningTimeChanged() {
        guard morningPrewarmEnabled else { return }
        scheduleMorningTimer()
        morningReapplyTask?.cancel()
        morningReapplyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard !Task.isCancelled else { return }
            await self?.applyHardwareWake()
        }
    }

    private func enableMorningPrewarm() async {
        morningPrewarmEnabled = true
        UserDefaults.standard.set(true, forKey: "morningPrewarmEnabled")
        let ok = await applyHardwareWake()
        if ok {
            scheduleMorningTimer()
        } else {
            // Admin cancelled / failed — revert so the UI reflects reality.
            morningPrewarmEnabled = false
            UserDefaults.standard.set(false, forKey: "morningPrewarmEnabled")
            morningTimer?.invalidate(); morningTimer = nil
        }
    }

    private func disableMorningPrewarm() async {
        morningPrewarmEnabled = false
        UserDefaults.standard.set(false, forKey: "morningPrewarmEnabled")
        morningTimer?.invalidate(); morningTimer = nil
        morningReapplyTask?.cancel()
        let result = await wakeScheduler.cancel()
        morningStatus = result.success ? "Morning pre-warm is off." : result.message
        addHistory(tool: nil, kind: .quotaFetch, title: "Morning pre-warm off", detail: result.message)
    }

    @discardableResult
    private func applyHardwareWake() async -> Bool {
        let days: WakeScheduler.WakeDays = morningWeekdaysOnly ? .weekdays : .everyday
        let result = await wakeScheduler.apply(hour: morningHour, minute: morningMinute, days: days)
        if result.success {
            let timeText = String(format: "%02d:%02d", morningHour, morningMinute)
            if WakeScheduler.isOnACPower() {
                morningStatus = "Mac will wake at \(timeText) and start your window."
            } else {
                morningStatus = "Scheduled for \(timeText), but on battery with the lid closed the wake may be skipped — your window warms the moment you open the lid."
            }
            addHistory(tool: nil, kind: .quotaFetch, title: "Morning pre-warm scheduled", detail: result.message)
        } else {
            morningStatus = result.message
        }
        return result.success
    }

    private func scheduleMorningTimer() {
        morningTimer?.invalidate()
        guard morningPrewarmEnabled, let fireDate = nextMorningFireDate() else { return }
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.runScheduledMorningWarmupIfNeeded(source: .timer) }
        }
        RunLoop.main.add(timer, forMode: .common)
        morningTimer = timer
    }

    private enum ScheduledMorningSource {
        case timer
        case wake
        case launch
    }

    /// Scheduled pre-warm is intentionally separate from fresh-reset detection:
    /// it may start a not-yet-active window after a missed launch/wake, so it
    /// must not depend on `resetAt` being present in quota API payloads.
    private func runScheduledMorningWarmupIfNeeded(source: ScheduledMorningSource) async {
        guard morningPrewarmEnabled, !globalPassive else { scheduleMorningTimer(); return }

        let now = Date()
        let todayKey = Self.dayKey(now)
        if morningWeekdaysOnly, Calendar.current.isDateInWeekend(now) {
            scheduleMorningTimer(); return
        }

        guard let scheduledAt = todaysMorningDate(now: now) else {
            scheduleMorningTimer(); return
        }

        var caughtUpSuccessfully = false
        for tool in ToolID.allCases where state(for: tool).isAutoWarmEnabled {
            let lastActivity = scanner.lastActivity(for: tool)
            let activeWindowStartedAt = scanner.windowStartTime(for: tool)
            let decision = MorningWarmupPolicy.decision(
                now: now,
                scheduledAt: scheduledAt,
                dayKey: todayKey,
                lastSuccessfulDay: lastMorningWarmDay(for: tool, todayKey: todayKey),
                lastActivity: lastActivity,
                activeWindowStartedAt: activeWindowStartedAt,
                windowDuration: tool.windowDuration
            )

            guard case .run(let caughtUp) = decision else { continue }
            guard canAttemptManagedWarmup(for: tool) else { continue }

            let previousQuotaFetchedAt = state(for: tool).quotaSnapshot?.fetchedAt
            let succeeded = await triggerWarmup(
                tool: tool,
                mode: caughtUp ? "scheduled-catchup" : "scheduled"
            )
            if succeeded {
                rememberMorningWarmSuccess(for: tool, dayKey: todayKey)
                claimAutoWindowFromPostWarmQuota(for: tool, previousFetchedAt: previousQuotaFetchedAt)
                caughtUpSuccessfully = caughtUpSuccessfully || caughtUp
            }
        }

        if caughtUpSuccessfully, source != .timer {
            NotificationManager.shared.notifyMorningCatchUp(onBattery: !WakeScheduler.isOnACPower())
        }
        scheduleMorningTimer()
    }

    private func handleSystemWake() {
        guard morningPrewarmEnabled else { return }
        guard let todaysMorning = todaysMorningDate(now: Date()), Date() >= todaysMorning else { return }
        Task { @MainActor in await runScheduledMorningWarmupIfNeeded(source: .wake) }
    }

    private func nextMorningFireDate() -> Date? {
        var comps = DateComponents()
        comps.hour = morningHour
        comps.minute = morningMinute
        comps.second = 0
        let cal = Calendar.current
        guard var next = cal.nextDate(after: Date(), matching: comps, matchingPolicy: .nextTime) else { return nil }
        if morningWeekdaysOnly {
            var guardCount = 0
            while cal.isDateInWeekend(next), guardCount < 8 {
                guard let bumped = cal.nextDate(after: next, matching: comps, matchingPolicy: .nextTime) else { break }
                next = bumped
                guardCount += 1
            }
        }
        return next
    }

    private func todaysMorningDate(now: Date = Date()) -> Date? {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: now)
        comps.hour = morningHour
        comps.minute = morningMinute
        comps.second = 0
        return Calendar.current.date(from: comps)
    }

    private var morningHour: Int { UserDefaults.standard.object(forKey: "morningPrewarmHour") as? Int ?? 6 }
    private var morningMinute: Int { UserDefaults.standard.object(forKey: "morningPrewarmMinute") as? Int ?? 0 }
    private var morningWeekdaysOnly: Bool { UserDefaults.standard.object(forKey: "morningPrewarmWeekdaysOnly") as? Bool ?? true }

    private func lastMorningWarmDay(for tool: ToolID, todayKey: String) -> String? {
        let perToolDay = UserDefaults.standard.string(forKey: "lastMorningWarmDay.\(tool.rawValue)")
        let legacyDay = UserDefaults.standard.string(forKey: "lastMorningWarmDay")
        let resolved = MorningWarmupPolicy.resolvedLastSuccessfulDay(
            perToolDay: perToolDay,
            legacyDay: legacyDay,
            currentDay: todayKey
        )
        if perToolDay == nil, resolved == todayKey {
            rememberMorningWarmSuccess(for: tool, dayKey: todayKey)
        }
        return resolved
    }

    private func rememberMorningWarmSuccess(for tool: ToolID, dayKey: String) {
        UserDefaults.standard.set(dayKey, forKey: "lastMorningWarmDay.\(tool.rawValue)")
    }

    private static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    func checkForAppUpdate() async {
        updateInfo = await updateChecker.checkForUpdate()
        addHistory(tool: nil, kind: .updateCheck, title: "Update checked", detail: updateInfo == nil ? "No update found" : "Update available")
    }

    private func attemptAutomaticWarmup(tool: ToolID, reason: String) async {
        let state = state(for: tool)
        guard canAttemptManagedWarmup(for: tool) else { return }

        await refreshQuotaForAutomaticDecision(tool: tool)
        guard state.sourceHealth == .healthy,
              state.canAutoWarmFromSnapshot,
              let snapshot = state.quotaSnapshot else {
            return
        }
        guard AutoWarmDedup.shouldWarm(
            currentWindowKey: snapshot.rawWindowKey,
            lastWarmedWindowKey: state.lastAutoWindowKey,
            lastWarmedWindowEndsAt: state.lastAutoWarmWindowEndsAt,
            currentWindowIsIdle: snapshot.fiveHour?.isIdle == true
        ) else {
            if let endsAt = state.lastAutoWarmWindowEndsAt, endsAt > Date() {
                DiagnosticLogger.append("auto_warm_skipped_active_window tool=\(tool.rawValue) windowEndsAt=\(ISO8601DateFormatter().string(from: endsAt))")
            }
            return
        }

        addHistory(tool: tool, kind: .resetDetected, title: "Fresh reset detected", detail: reason)
        let previousFetchedAt = snapshot.fetchedAt
        let succeeded = await triggerWarmup(tool: tool, mode: "auto")
        // Only claim the window once a warm-up actually succeeded. Marking it on
        // failure would burn the dedup slot and leave a fresh window unwarmed
        // until the next reset; instead, let the next refresh retry (under backoff).
        //
        // Claim the *post-warm* window key, not the pre-warm one: warming an idle
        // Codex window opens it, so the pre-warm snapshot's stable "idle" key would
        // wrongly match — and block — the next idle period's claim. Keying on the
        // freshly-opened (now active) window lets each later idle window re-claim.
        if succeeded {
            claimAutoWindowFromPostWarmQuota(for: tool, previousFetchedAt: previousFetchedAt)
        }
    }

    private func canAttemptManagedWarmup(for tool: ToolID) -> Bool {
        let state = state(for: tool)
        guard state.isAutoWarmEnabled, !globalPassive, !state.isWarming else { return false }
        guard state.authStatus != .failed, state.authStatus != .missing else { return false }
        if UserDefaults.standard.object(forKey: "rateLimitGuard") as? Bool ?? true,
           let backoffUntil = state.backoffUntil,
           backoffUntil > Date() {
            return false
        }
        return true
    }

    private func claimAutoWindowFromPostWarmQuota(for tool: ToolID, previousFetchedAt: Date?) {
        let state = state(for: tool)
        guard let snapshot = state.quotaSnapshot,
              // If the post-warm quota still reads idle (e.g. the API hasn't caught
              // up to the just-sent command), don't store the stable "idle" key — it
              // would block the next idle period's claim. Leave the prior key in
              // place; `lastAutoWarmWindowEndsAt` already guards against re-warming.
              snapshot.fiveHour?.isIdle != true,
              snapshot.isClaimableAutoWindow(previousFetchedAt: previousFetchedAt) else {
            return
        }
        state.rememberAutoWindow(snapshot.rawWindowKey)
    }

    private func refreshQuotaForAutomaticDecision(tool: ToolID) async {
        let state = state(for: tool)
        if state.freshness == .fresh, state.sourceHealth != .rateLimited { return }
        await refreshQuota(for: tool, allowAutomaticWarmup: false)
    }

    @discardableResult
    private func triggerWarmup(tool: ToolID, mode: String) async -> Bool {
        let state = state(for: tool)
        guard !state.isWarming else { return false }

        state.isWarming = true
        state.errorMessage = nil
        state.claimVerifyTask?.cancel(); state.claimVerifyTask = nil
        state.settleRepollTask?.cancel(); state.settleRepollTask = nil
        notifications.cancelAll(for: tool)

        var succeeded = false
        do {
            let result = try await runner.warmup(tool)
            let entry = WarmupLog(timestamp: result.date, mode: mode, command: result.command, output: result.output)
            state.warmupLogs.insert(entry, at: 0)
            if state.warmupLogs.count > 20 { state.warmupLogs.removeLast() }
            state.backoffUntil = nil
            addHistory(
                tool: tool,
                kind: historyKind(forWarmupMode: mode),
                title: historyTitle(forWarmupMode: mode),
                detail: "Command completed"
            )
            notifications.notifyWarmupCommandSent(tool: tool)
            state.lastWarmupOutcome = .pending(sentAt: result.date)
            await refreshQuota(for: tool, allowAutomaticWarmup: false)
            // No *real* live window yet: either no reset at all, or only an idle
            // "if you started now" projection (Claude's null `five_hour` is now
            // surfaced as an idle window with a sliding reset). Record the
            // command's expected reset so the confirm path (evaluateWarmupClaim)
            // has a stable boundary to trust instead of the sliding projection.
            let liveMetric = state.primaryMetric
            if liveMetric?.resetAt == nil || liveMetric?.isIdle == true {
                state.rememberConfirmedWarmup(startedAt: result.date, duration: tool.windowDuration)
            }
            // Remember when this freshly-claimed window resets so the auto path
            // won't re-warm it on the next poll (see attemptAutomaticWarmup).
            state.rememberAutoWarmWindowEnd(state.resetAt ?? result.date.addingTimeInterval(tool.windowDuration))
            // Prove the window actually opened (not just that the command exited
            // zero). Confirmed now, or re-checked after a bounded grace period.
            evaluateWarmupClaim(for: tool, sentAt: result.date, attempt: 0)
            succeeded = true
        } catch WarmupError.authenticationRequired(let message) {
            state.errorMessage = message
            state.healthMessage = message
            state.sourceHealth = .authFailure
            state.authStatus = .failed
            state.backoffUntil = nil
            state.lastWarmupOutcome = .failed(at: Date(), reason: message)
            addHistory(tool: tool, kind: .authFailure, title: "Warmup blocked", detail: message)
            scheduleClaudeAuthRecheckIfNeeded(for: state, reason: message)
        } catch {
            state.errorMessage = error.localizedDescription
            state.backoffUntil = Date().addingTimeInterval(nextBackoff(for: state))
            state.lastWarmupOutcome = .failed(at: Date(), reason: error.localizedDescription)
            addHistory(tool: tool, kind: .pollingError, title: "Warmup failed", detail: error.localizedDescription)
        }

        state.isWarming = false
        return succeeded
    }

    /// Grace delays for re-checking that a warm-up actually opened the window,
    /// to tolerate provider lag before falling back to the assumed window. Bounded.
    private let claimVerifyDelays: [TimeInterval] = [30, 90]

    /// Evaluates the live (post-warm) snapshot: marks the window confirmed, or
    /// schedules a bounded grace re-check, or — once attempts are exhausted —
    /// confirms against the completed command's expected (assumed) window.
    private func evaluateWarmupClaim(for tool: ToolID, sentAt: Date, attempt: Int) {
        let state = state(for: tool)
        if state.quotaSnapshot?.showsActiveWindow() == true {
            state.claimVerifyTask?.cancel(); state.claimVerifyTask = nil
            state.lastWarmupOutcome = .confirmed(at: Date(), resetAt: state.resetAt)
            addHistory(tool: tool, kind: .resetDetected, title: "Window claim confirmed", detail: claimConfirmedDetail(state))
            DiagnosticLogger.append("warmup_claim_confirmed tool=\(tool.rawValue) attempt=\(attempt)")
            if state.sourceHealth == .healthy {
                notifications.notifyActivated(tool: tool)
            }
            // The window's reset time is right, but right at rollover the provider
            // can pair it with the just-ended window's high utilization (reads as
            // "0% left"). Re-poll a few times so the settled percentage lands in
            // seconds instead of waiting for the next 5-minute refresh.
            scheduleSettleRepoll(for: tool)
            return
        }

        guard attempt < claimVerifyDelays.count else {
            // Grace exhausted without the live API surfacing the window. The
            // warm-up command itself completed (we're on the success path) and
            // triggerWarmup always recorded the window's expected reset
            // (`confirmedWarmupResetAt`) when the live quota lacked one, so trust
            // that rather than alarming the user — Claude's OAuth usage API
            // frequently reports the active 5h window as idle/null for minutes
            // after it opens, and the verification timer can be suspended across
            // system sleep. A later poll that surfaces the live window keeps the
            // reset accurate via reconcileWarmupOutcome().
            state.lastWarmupOutcome = .confirmed(at: Date(), resetAt: state.confirmedWarmupResetAt ?? state.resetAt)
            addHistory(tool: tool, kind: .resetDetected, title: "Warm-up sent", detail: claimConfirmedDetail(state))
            DiagnosticLogger.append("warmup_claim_assumed tool=\(tool.rawValue)")
            return
        }

        let delay = claimVerifyDelays[attempt]
        state.lastWarmupOutcome = .pending(sentAt: sentAt)
        state.claimVerifyTask?.cancel()
        DiagnosticLogger.append("warmup_claim_recheck tool=\(tool.rawValue) attempt=\(attempt + 1) delay=\(Int(delay))s")
        state.claimVerifyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.runClaimVerification(tool: tool, sentAt: sentAt, attempt: attempt + 1)
        }
    }

    /// Heals a stuck warm-up status on regular polls (outside the bounded in-warm
    /// verification): a `.pending` outcome whose recheck task was lost (e.g.
    /// cancelled without resolving) is upgraded to `.confirmed` once a later
    /// snapshot actually shows the window open — this covers Claude's laggy
    /// `five_hour` reporting and verification suspended across system sleep. A
    /// `.pending` whose warmed window has fully elapsed without ever confirming
    /// is cleared so the status card doesn't linger for hours.
    private func reconcileWarmupOutcome(for state: ToolState) {
        switch state.lastWarmupOutcome {
        case .pending(let sentAt):
            if state.quotaSnapshot?.showsActiveWindow() == true {
                state.claimVerifyTask?.cancel(); state.claimVerifyTask = nil
                state.lastWarmupOutcome = .confirmed(at: Date(), resetAt: state.resetAt)
                addHistory(tool: state.tool, kind: .resetDetected, title: "Window claim confirmed", detail: claimConfirmedDetail(state))
                DiagnosticLogger.append("warmup_claim_healed tool=\(state.tool.rawValue)")
            } else if Date().timeIntervalSince(sentAt) > state.tool.windowDuration {
                state.lastWarmupOutcome = .none
            }
        default:
            break
        }
    }

    private func runClaimVerification(tool: ToolID, sentAt: Date, attempt: Int) async {
        let state = state(for: tool)
        guard state.claimVerifyTask != nil else { return }
        state.claimVerifyTask = nil
        await refreshQuota(for: tool, allowAutomaticWarmup: false, reconcileStuckOutcome: false)
        evaluateWarmupClaim(for: tool, sentAt: sentAt, attempt: attempt)
    }

    /// Short, bounded follow-up polls that run only while the live 5h reading is
    /// an unsettled rollover artifact (`sessionSettling`). Stops as soon as the
    /// provider returns the real percentage, or after the last delay. Distinct
    /// from `claimVerifyTask` (which proves the *window* opened, and stops on
    /// confirmation) — this exists purely to settle the displayed *quota*.
    private let settleRepollDelays: [TimeInterval] = [20, 45, 90]

    private func scheduleSettleRepoll(for tool: ToolID, attempt: Int = 0) {
        let state = state(for: tool)
        guard state.sessionSettling, attempt < settleRepollDelays.count else {
            state.settleRepollTask?.cancel(); state.settleRepollTask = nil
            return
        }
        let delay = settleRepollDelays[attempt]
        state.settleRepollTask?.cancel()
        DiagnosticLogger.append("quota_settle_repoll tool=\(tool.rawValue) attempt=\(attempt + 1) delay=\(Int(delay))s")
        state.settleRepollTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.refreshQuota(for: tool, allowAutomaticWarmup: false, reconcileStuckOutcome: false)
            self?.scheduleSettleRepoll(for: tool, attempt: attempt + 1)
        }
    }

    private func claimConfirmedDetail(_ state: ToolState) -> String {
        guard let reset = state.resetAt else { return "Window is active." }
        let seconds = max(0, Int(reset.timeIntervalSinceNow))
        return "Window active · resets in \(seconds / 3600)h \((seconds % 3600) / 60)m"
    }

    private func historyKind(forWarmupMode mode: String) -> HistoryKind {
        switch mode {
        case "auto", "scheduled", "scheduled-catchup":
            return .autoWarmup
        default:
            return .manualWarmup
        }
    }

    private func historyTitle(forWarmupMode mode: String) -> String {
        switch mode {
        case "auto":
            return "Auto warmup sent"
        case "scheduled":
            return "Scheduled warmup sent"
        case "scheduled-catchup":
            return "Scheduled catch-up warmup sent"
        default:
            return "Manual warmup sent"
        }
    }

    private func applyQuotaBackoff(for state: ToolState, retryAfter: TimeInterval?) -> Date {
        let baseDelay: TimeInterval = 5 * 60
        let maxDelay: TimeInterval = 60 * 60
        let fallbackDelay = state.quotaBackoffDelay > 0
            ? min(state.quotaBackoffDelay * 2, maxDelay)
            : baseDelay
        let delay = max(fallbackDelay, retryAfter ?? 0)
        let retryAt = Date().addingTimeInterval(delay)

        state.quotaBackoffDelay = delay
        state.quotaBackoffUntil = retryAt
        state.nextRefreshAt = retryAt
        scheduleQuotaRefresh(for: state.tool, at: retryAt)
        return retryAt
    }

    private func clearQuotaBackoff(for state: ToolState) {
        state.quotaBackoffUntil = nil
        state.quotaBackoffDelay = 0
    }

    private func clearAuthRetry(for state: ToolState) {
        state.authRetryTask?.cancel()
        state.authRetryTask = nil
        state.authRetryAttempts = 0
        state.authRetryScheduledAt = nil
    }

    private func applyCLIAuthenticationStatusIfNeeded(for tool: ToolID, to state: ToolState) async -> Bool {
        guard tool == .claude else { return true }

        switch await runner.cliAuthenticationStatus(for: tool) {
        case .authenticated:
            if state.authStatus == .failed || state.authStatus == .missing {
                addHistory(tool: tool, kind: .quotaFetch, title: "Claude CLI auth restored", detail: "Warmup can run again")
            }
            state.authStatus = .available
            if state.sourceHealth == .authFailure, let snapshot = state.quotaSnapshot {
                state.sourceHealth = snapshot.freshness() == .fresh ? .healthy : .stale
            }
            if state.errorMessage == WarmupRunner.claudeLoginRequiredMessage {
                state.errorMessage = nil
            }
            state.backoffUntil = nil
            // Cancel any pending retry task but preserve authRetryAttempts so that
            // if the subsequent refreshQuota call also fails, scheduleClaudeAuthRecheckIfNeeded
            // continues from the current attempt index instead of restarting from 0.
            // authRetryAttempts is only reset to 0 by the refreshQuota success path.
            state.authRetryTask?.cancel()
            state.authRetryTask = nil
            state.authRetryScheduledAt = nil
            return true
        case .notAuthenticated(let message):
            let wasAlreadyBlocked = state.authStatus == .failed && state.errorMessage == message
            state.authStatus = .failed
            state.sourceHealth = .authFailure
            state.errorMessage = message
            state.healthMessage = message
            state.backoffUntil = nil
            if !wasAlreadyBlocked {
                addHistory(tool: tool, kind: .authFailure, title: "Claude CLI login required", detail: message)
            }
            scheduleClaudeAuthRecheckIfNeeded(for: state, reason: message)
            return false
        case .unknown(let message):
            DiagnosticLogger.append("cli_auth_status_unknown tool=\(tool.rawValue) reason=\(message)")
            return true
        }
    }

    private func scheduleQuotaRefresh(for tool: ToolID, at date: Date) {
        guard state(for: tool).isMonitored, !globalPassive else { return }
        scheduler.schedule(tool: tool, at: date)
    }

    private func rateLimitMessage(until date: Date) -> String {
        "rate limited; retry at \(shortTime(date))"
    }

    private func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func applyQuotaError(_ error: Error, to state: ToolState) {
        let message = error.localizedDescription
        state.errorMessage = message
        state.healthMessage = message

        if let providerError = error as? QuotaProviderError {
            switch providerError {
            case .authFailure:
                clearQuotaBackoff(for: state)
                state.sourceHealth = .authFailure
                state.authStatus = .failed
                addHistory(tool: state.tool, kind: .authFailure, title: "Authorization failed", detail: message)
                scheduleClaudeAuthRecheckIfNeeded(for: state, reason: message)
            case .missingCredentials:
                clearQuotaBackoff(for: state)
                state.sourceHealth = .authFailure
                state.authStatus = .missing
                addHistory(tool: state.tool, kind: .authFailure, title: "Credentials missing", detail: message)
                scheduleClaudeAuthRecheckIfNeeded(for: state, reason: message)
            case .rateLimited(_, let retryAfter):
                clearAuthRetry(for: state)
                let retryAt = applyQuotaBackoff(for: state, retryAfter: retryAfter)
                let retryMessage = rateLimitMessage(until: retryAt)
                state.sourceHealth = .rateLimited
                state.authStatus = .available
                state.errorMessage = retryMessage
                state.healthMessage = retryMessage
                addHistory(tool: state.tool, kind: .rateLimit, title: "Rate limited", detail: "\(message). Retrying at \(shortTime(retryAt)).")
            case .unavailable, .malformed:
                clearQuotaBackoff(for: state)
                clearAuthRetry(for: state)
                state.sourceHealth = state.quotaSnapshot == nil ? .unavailable : .stale
                addHistory(tool: state.tool, kind: .pollingError, title: "Quota fetch failed", detail: message)
            }
        } else {
            clearQuotaBackoff(for: state)
            clearAuthRetry(for: state)
            state.sourceHealth = state.quotaSnapshot == nil ? .unavailable : .stale
            addHistory(tool: state.tool, kind: .pollingError, title: "Quota fetch failed", detail: message)
        }
    }

    private func quotaFetchDetail(_ snapshot: QuotaSnapshot) -> String {
        var parts = [snapshot.primarySource]
        if let corroborating = snapshot.corroboratingSource {
            parts.append("checked \(corroborating)")
        }
        if let credentialSource = snapshot.message, !credentialSource.isEmpty {
            parts.append("via \(credentialSource)")
        }
        return parts.joined(separator: ", ")
    }

    private func scheduleClaudeAuthRecheckIfNeeded(for state: ToolState, reason: String) {
        guard state.tool == .claude, state.isMonitored, !globalPassive else { return }
        guard state.authRetryAttempts < claudeAuthRetryDelays.count else {
            DiagnosticLogger.append(
                "auth_recheck_exhausted tool=\(state.tool.rawValue) attempts=\(state.authRetryAttempts) reason=\(reason)"
            )
            return
        }

        state.authRetryTask?.cancel()
        let delay = claudeAuthRetryDelays[state.authRetryAttempts]
        state.authRetryAttempts += 1
        let attempt = state.authRetryAttempts
        let retryAt = Date().addingTimeInterval(delay)
        state.authRetryScheduledAt = retryAt
        state.nextRefreshAt = retryAt

        addHistory(
            tool: state.tool,
            kind: .quotaFetch,
            title: "Auth recheck scheduled",
            detail: "Retry \(attempt)/\(claudeAuthRetryDelays.count) at \(shortTime(retryAt)) after Claude login"
        )
        DiagnosticLogger.append(
            "auth_recheck_scheduled tool=\(state.tool.rawValue) attempt=\(attempt) retryAt=\(ISO8601DateFormatter().string(from: retryAt)) reason=\(reason)"
        )

        state.authRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.runClaudeAuthRecheck(attempt: attempt)
        }
    }

    private func runClaudeAuthRecheck(attempt: Int) async {
        let state = state(for: .claude)
        guard state.authRetryAttempts == attempt else { return }
        state.authRetryTask = nil
        state.authRetryScheduledAt = nil
        DiagnosticLogger.append("auth_recheck_running tool=claude attempt=\(attempt)")
        guard await applyCLIAuthenticationStatusIfNeeded(for: .claude, to: state) else { return }
        await refreshQuota(for: .claude, allowAutomaticWarmup: false)
    }

    private func rescheduleRefresh(for tool: ToolID) {
        let state = state(for: tool)
        guard state.isMonitored, !globalPassive else {
            scheduler.invalidate(tool: tool)
            state.nextRefreshAt = nil
            return
        }
        let nextDate = Date().addingTimeInterval(refreshInterval)
        scheduler.schedule(tool: tool, at: nextDate)
        state.nextRefreshAt = nextDate
        // Use the *real* window reset, not the idle "if you started now"
        // projection that `resetAt` falls back to — otherwise an idle window
        // (e.g. Claude's null `five_hour`) would schedule a misleading
        // "window expiring soon" notification for a window that never opened.
        if let resetAt = state.realWindowResetAt, resetAt > Date() {
            notifications.scheduleWindowWarning(for: tool, expiresAt: resetAt)
        }
    }

    private func startQuotaRefreshTimer() {
        quotaTimer?.invalidate()
        quotaTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllActivity(allowAutomaticWarmup: true)
            }
        }
    }

    private func startUIRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.toolStates.values.forEach { $0.objectWillChange.send() }
                // Also poke AppState so the menu-bar label (which observes
                // AppState, not each ToolState) re-renders its countdown.
                self.objectWillChange.send()
            }
        }
    }

    private var quotaTimer: Timer?

    private var refreshInterval: TimeInterval {
        let stored = UserDefaults.standard.integer(forKey: "refreshInterval")
        return TimeInterval(stored.nonZero ?? 300)
    }

    private func addHistory(tool: ToolID?, kind: HistoryKind, title: String, detail: String) {
        let event = HistoryEvent(timestamp: Date(), tool: tool, kind: kind, title: title, detail: detail)
        history.insert(event, at: 0)
        if history.count > 10 { history.removeLast(history.count - 10) }
        DiagnosticLogger.appendHistory(event)
    }

    private func nextBackoff(for state: ToolState) -> TimeInterval {
        if let backoffUntil = state.backoffUntil, backoffUntil > Date() {
            return min(backoffUntil.timeIntervalSinceNow * 2, 30 * 60)
        }
        return 5 * 60
    }

    private func checkOnboarding() async {
        var anyMissing = false
        for tool in ToolID.allCases {
            if await runner.cliMissing(tool) { anyMissing = true }
        }
        if anyMissing && !UserDefaults.standard.bool(forKey: "onboardingDismissed") {
            showOnboarding = true
        }
    }
}

/// Diagnostic logging verbosity, set from the menu-bar right-click menu.
/// `.off` silences the on-disk diagnostics log entirely.
enum DebugLevel: Int, CaseIterable {
    case off = 0
    case normal = 1
    case verbose = 2

    var title: String {
        switch self {
        case .off:     return "Off"
        case .normal:  return "Normal"
        case .verbose: return "Verbose"
        }
    }

    static var current: DebugLevel {
        get {
            let raw = UserDefaults.standard.object(forKey: "debugLevel") as? Int ?? DebugLevel.normal.rawValue
            return DebugLevel(rawValue: raw) ?? .normal
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "debugLevel") }
    }
}

enum DiagnosticLogger {
    static let fileURL = URL(fileURLWithPath: "/tmp/quotawarmer-diagnostics.log")

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func appendHistory(_ event: HistoryEvent) {
        let tool = event.tool?.rawValue ?? "app"
        append("history tool=\(tool) kind=\(event.kind.rawValue) title=\(event.title) detail=\(event.detail)")
    }

    static func append(_ message: String) {
        guard DebugLevel.current != .off else { return }
        let line = "[\(formatter.string(from: Date()))] \(redacted(message))\n"
        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: fileURL.path),
           let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func redacted(_ text: String) -> String {
        var output = text
        let patterns = [
            #"sk-[A-Za-z0-9._-]{12,}"#,
            #"Bearer\s+[A-Za-z0-9._-]{12,}"#,
            #"Authorization[:=]\s*[A-Za-z0-9._\-\s]{12,}"#
        ]

        for pattern in patterns {
            output = output.replacingOccurrences(
                of: pattern,
                with: "<redacted>",
                options: .regularExpression
            )
        }
        return output
    }
}
