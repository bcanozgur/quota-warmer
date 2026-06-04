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

    @Published var isActive: Bool {
        didSet { UserDefaults.standard.set(isActive, forKey: "toolActive.\(tool.rawValue)") }
    }
    /// Whether this tool's glyph + quota is pinned to the menu bar. Independent
    /// of `isActive` — a passive tool can still be watched in the menu bar.
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
    @Published var lastAutoWindowKey: String?
    @Published var warmupLogs: [WarmupLog] = []
    @Published var isLogExpanded = false

    init(tool: ToolID) {
        self.tool = tool
        self.isActive = UserDefaults.standard.object(forKey: "toolActive.\(tool.rawValue)") as? Bool ?? false
        self.menuBarVisible = UserDefaults.standard.object(forKey: "menuBarVisible.\(tool.rawValue)") as? Bool ?? true
        self.lastAutoWindowKey = UserDefaults.standard.string(forKey: "lastAutoWindowKey.\(tool.rawValue)")
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

    var resetAt: Date? {
        primaryMetric?.resetAt
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
        guard freshness == .fresh, let metric = primaryMetric else { return false }
        let remaining = metric.remainingFraction
        if remaining >= 0.95 { return true }
        if let resetAt = metric.resetAt, resetAt <= Date().addingTimeInterval(60) { return true }
        return false
    }

    func rememberAutoWindow(_ key: String) {
        lastAutoWindowKey = key
        UserDefaults.standard.set(key, forKey: "lastAutoWindowKey.\(tool.rawValue)")
    }
}

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {
    @Published var showOnboarding = false
    @Published var isRefreshing = false
    @Published var updateInfo: ReleaseInfo?
    @Published private(set) var toolStates: [ToolID: ToolState]
    @Published var history: [HistoryEvent] = []
    @Published var morningPrewarmEnabled: Bool = UserDefaults.standard.bool(forKey: "morningPrewarmEnabled")
    @Published var morningStatus: String?
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
            Task { @MainActor [weak self] in self?.handleSystemWake() }
        }

        refreshAllActivity(allowAutomaticWarmup: false)
        startQuotaRefreshTimer()
        startUIRefreshTimer()
        if morningPrewarmEnabled { scheduleMorningTimer() }
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

    func setActive(_ active: Bool, for tool: ToolID) {
        let state = state(for: tool)
        state.isActive = active
        if active {
            addHistory(tool: tool, kind: .quotaFetch, title: "Activated", detail: "Automatic warmup enabled after fresh quota checks")
            Task { await refreshQuota(for: tool, allowAutomaticWarmup: true) }
        } else {
            scheduler.invalidate(tool: tool)
            notifications.cancelAll(for: tool)
            addHistory(tool: tool, kind: .quotaFetch, title: "Passive", detail: "Automatic warmup disabled")
        }
    }

    func activate(_ tool: ToolID) {
        Task { await triggerWarmup(tool: tool, mode: "manual") }
    }

    func refreshAllActivity(allowAutomaticWarmup: Bool = false, includeInactive: Bool = false) {
        isRefreshing = true
        let tools = ToolID.allCases.filter { includeInactive || state(for: $0).isActive }
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

    func refreshQuota(for tool: ToolID, allowAutomaticWarmup: Bool = false) async {
        let state = state(for: tool)
        state.isFetchingQuota = true
        state.errorMessage = nil

        do {
            let snapshot = try await quotaProvider.fetchQuota(for: tool)
            state.quotaSnapshot = snapshot
            state.sourceHealth = snapshot.freshness() == .fresh ? .healthy : .stale
            state.authStatus = .available
            state.healthMessage = snapshot.message ?? snapshot.primarySource
            state.nextRefreshAt = Date().addingTimeInterval(refreshInterval)
            addHistory(
                tool: tool,
                kind: .quotaFetch,
                title: "Quota fetched",
                detail: snapshot.corroboratingSource.map { "\(snapshot.primarySource), checked \($0)" } ?? snapshot.primarySource
            )
            rescheduleRefresh(for: tool)

            if allowAutomaticWarmup {
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
        for tool in ToolID.allCases where state(for: tool).isActive {
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
            Task { @MainActor [weak self] in await self?.runMorningWarmup(viaWake: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        morningTimer = timer
    }

    /// Single morning-warm entry point, deduplicated to once per calendar day so
    /// the in-app timer and the system-wake handler can both route here safely.
    private func runMorningWarmup(viaWake: Bool) async {
        let todayKey = Self.dayKey(Date())
        guard lastMorningWarmDay != todayKey else { scheduleMorningTimer(); return }
        if morningWeekdaysOnly, Calendar.current.isDateInWeekend(Date()) {
            scheduleMorningTimer(); return
        }
        lastMorningWarmDay = todayKey

        let lateness = todaysMorningDate().map { Date().timeIntervalSince($0) } ?? 0
        let caughtUp = viaWake && lateness > 15 * 60

        for tool in ToolID.allCases where state(for: tool).isActive {
            await attemptAutomaticWarmup(
                tool: tool,
                reason: caughtUp ? "morning pre-warm (caught up on wake)" : "morning pre-warm"
            )
        }
        if caughtUp {
            NotificationManager.shared.notifyMorningCatchUp(onBattery: !WakeScheduler.isOnACPower())
        }
        scheduleMorningTimer()
    }

    private func handleSystemWake() {
        guard morningPrewarmEnabled else { return }
        guard let todaysMorning = todaysMorningDate(), Date() >= todaysMorning else { return }
        Task { @MainActor in await runMorningWarmup(viaWake: true) }
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

    private func todaysMorningDate() -> Date? {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = morningHour
        comps.minute = morningMinute
        comps.second = 0
        return Calendar.current.date(from: comps)
    }

    private var morningHour: Int { UserDefaults.standard.object(forKey: "morningPrewarmHour") as? Int ?? 6 }
    private var morningMinute: Int { UserDefaults.standard.object(forKey: "morningPrewarmMinute") as? Int ?? 0 }
    private var morningWeekdaysOnly: Bool { UserDefaults.standard.object(forKey: "morningPrewarmWeekdaysOnly") as? Bool ?? true }

    private var lastMorningWarmDay: String? {
        get { UserDefaults.standard.string(forKey: "lastMorningWarmDay") }
        set { UserDefaults.standard.set(newValue, forKey: "lastMorningWarmDay") }
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
        guard state.isActive, !globalPassive else { return }
        guard !state.isWarming else { return }
        if UserDefaults.standard.object(forKey: "rateLimitGuard") as? Bool ?? true,
           let backoffUntil = state.backoffUntil,
           backoffUntil > Date() {
            return
        }

        await refreshQuotaForAutomaticDecision(tool: tool)
        guard state.canAutoWarmFromSnapshot, let snapshot = state.quotaSnapshot else {
            return
        }
        guard state.lastAutoWindowKey != snapshot.rawWindowKey else {
            return
        }

        addHistory(tool: tool, kind: .resetDetected, title: "Fresh reset detected", detail: reason)
        await triggerWarmup(tool: tool, mode: "auto")
        state.rememberAutoWindow(snapshot.rawWindowKey)
    }

    private func refreshQuotaForAutomaticDecision(tool: ToolID) async {
        let state = state(for: tool)
        if state.freshness == .fresh { return }
        await refreshQuota(for: tool, allowAutomaticWarmup: false)
    }

    private func triggerWarmup(tool: ToolID, mode: String) async {
        let state = state(for: tool)
        guard !state.isWarming else { return }

        state.isWarming = true
        state.errorMessage = nil
        notifications.cancelAll(for: tool)

        do {
            let result = try await runner.warmup(tool)
            let entry = WarmupLog(timestamp: result.date, mode: mode, command: result.command, output: result.output)
            state.warmupLogs.insert(entry, at: 0)
            if state.warmupLogs.count > 20 { state.warmupLogs.removeLast() }
            state.backoffUntil = nil
            addHistory(
                tool: tool,
                kind: mode == "auto" ? .autoWarmup : .manualWarmup,
                title: mode == "auto" ? "Auto warmup sent" : "Manual warmup sent",
                detail: "Command completed"
            )
            notifications.notifyActivated(tool: tool)
            await refreshQuota(for: tool, allowAutomaticWarmup: false)
        } catch {
            state.errorMessage = error.localizedDescription
            state.backoffUntil = Date().addingTimeInterval(nextBackoff(for: state))
            addHistory(tool: tool, kind: .pollingError, title: "Warmup failed", detail: error.localizedDescription)
        }

        state.isWarming = false
    }

    private func applyQuotaError(_ error: Error, to state: ToolState) {
        let message = error.localizedDescription
        state.errorMessage = message
        state.healthMessage = message

        if let providerError = error as? QuotaProviderError {
            switch providerError {
            case .authFailure:
                state.sourceHealth = .authFailure
                state.authStatus = .failed
                addHistory(tool: state.tool, kind: .authFailure, title: "Authorization failed", detail: message)
            case .missingCredentials:
                state.sourceHealth = .authFailure
                state.authStatus = .missing
                addHistory(tool: state.tool, kind: .authFailure, title: "Credentials missing", detail: message)
            case .rateLimited:
                state.sourceHealth = .rateLimited
                state.authStatus = .available
                addHistory(tool: state.tool, kind: .rateLimit, title: "Rate limited", detail: message)
            case .unavailable, .malformed:
                state.sourceHealth = state.quotaSnapshot == nil ? .unavailable : .stale
                addHistory(tool: state.tool, kind: .pollingError, title: "Quota fetch failed", detail: message)
            }
        } else {
            state.sourceHealth = state.quotaSnapshot == nil ? .unavailable : .stale
            addHistory(tool: state.tool, kind: .pollingError, title: "Quota fetch failed", detail: message)
        }
    }

    private func rescheduleRefresh(for tool: ToolID) {
        let state = state(for: tool)
        guard state.isActive, !globalPassive else {
            scheduler.invalidate(tool: tool)
            state.nextRefreshAt = nil
            return
        }
        let nextDate = Date().addingTimeInterval(refreshInterval)
        scheduler.schedule(tool: tool, at: nextDate)
        state.nextRefreshAt = nextDate
        if let resetAt = state.resetAt, resetAt > Date() {
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
        history.insert(HistoryEvent(timestamp: Date(), tool: tool, kind: kind, title: title, detail: detail), at: 0)
        if history.count > 10 { history.removeLast(history.count - 10) }
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
