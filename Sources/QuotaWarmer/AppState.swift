import AppKit
import Combine
import Foundation

// MARK: - AppState

/// The `ObservableObject` facade Views observe. It owns the published state
/// (accounts, per-account `ToolState`, history, morning status, panel state),
/// the timers and the shared services; behavior lives in the coordinators
/// under `Coordinators/`, which reach this state through `CoordinatorHost`.
/// Settings are read through `AppSettings`.
@MainActor
final class AppState: ObservableObject, CoordinatorHost {
    @Published var showOnboarding = false
    /// Full first-run guide (see `OnboardingFlow`); separate from the missing-CLI banner above.
    @Published var showWelcomeGuide = false
    /// Captured before init writes any default, so a fresh install is distinguishable from an upgrade.
    private let hadPriorSettings = OnboardingFlow.hasPriorSettings(
        keys: Array(UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?.keys ?? [:].keys))
    @Published var isRefreshing = false
    /// Which tab the panel shows. Lifted out of `MenuContent` so the menu-bar
    /// right-click menu ("Show Stats" / "Go to Settings") can drive it.
    @Published var selectedTab: AppTab = .main
    @Published var updateInfo: ReleaseInfo?
    /// Per-account state. Mutated only by `AccountsCoordinator`.
    @Published var toolStates: [ProviderID: ToolState]
    /// Accounts the user added on top of each CLI's default account. Mutated
    /// only by `AccountsCoordinator`.
    @Published var accounts: [ProviderAccount]
    @Published var history: [HistoryEvent] = []
    @Published var morningPrewarmEnabled: Bool
    @Published var morningStatus: String?
    /// Most recent successful quota poll across all tools. Drives the liveness
    /// watchdog so a silently-stalled app stops looking "all good."
    @Published var lastSuccessfulPollAt: Date?
    @Published var globalPassive: Bool {
        didSet {
            settings.globalPassive = globalPassive
            if globalPassive {
                scheduler.invalidateAll()
                providers.forEach { notifications.cancelAll(for: $0) }
            } else {
                refreshAllActivity(allowAutomaticWarmup: true)
            }
        }
    }

    let settings = AppSettings.shared
    private let runner = WarmupRunner()
    private let scheduler = Scheduler()
    private let notifications = NotificationManager.shared
    private let updateChecker = UpdateChecker()
    private let quotaProvider: QuotaProviding = QuotaProvider()
    private var refreshTimer: Timer?
    private var quotaTimer: Timer?

    lazy var events = EventHistoryCoordinator(host: self)
    lazy var quota = QuotaPollingCoordinator(
        host: self, quotaProvider: quotaProvider, runner: runner, scheduler: scheduler, notifications: notifications)
    lazy var warmup = WarmupCoordinator(host: self, runner: runner, notifications: notifications)
    lazy var morning = MorningCoordinator(host: self, scheduler: scheduler)
    private lazy var accountsCoordinator = AccountsCoordinator(
        host: self, scheduler: scheduler, notifications: notifications)

    init() {
        settings.migrateIfNeeded()
        let storedAccounts = ProviderAccount.load()
        accounts = storedAccounts
        var states: [ProviderID: ToolState] = [:]
        for tool in Self.orderedProviders(accounts: storedAccounts) { states[tool] = ToolState(tool: tool) }
        toolStates = states
        globalPassive = settings.globalPassive
        morningPrewarmEnabled = settings.morningPrewarmEnabled

        scheduler.onFire = { [weak self] tool in
            Task { @MainActor [weak self] in
                await self?.warmup.attemptAutomaticWarmup(tool: tool, reason: "scheduled refresh")
            }
        }
        scheduler.providers = { [weak self] in
            MainActor.assumeIsolated { self?.providers ?? [] }
        }
        scheduler.onWake = { [weak self] in
            Task { @MainActor [weak self] in
                // Give polling a grace period after wake so the sleep gap isn't
                // mistaken for a stalled app; the per-tool fires that follow
                // will refresh this on success.
                self?.lastSuccessfulPollAt = Date()
                self?.morning.handleSystemWake()
            }
        }

        events.loadPersistedHistory()
        refreshAllActivity(allowAutomaticWarmup: false)
        startQuotaRefreshTimer()
        startUIRefreshTimer()
        if morningPrewarmEnabled {
            morning.scheduleMorningTimer()
            morning.refreshMorningHardwareStatus()
            Task { await morning.runScheduledMorningWarmupIfNeeded(source: .launch) }
        }
        Task { await checkOnboarding() }
        Task { await checkForAppUpdate() }
        Task.detached(priority: .utility) {
            for tool in ToolID.allCases {
                let store = ModelCatalogStore.shared(for: tool)
                DiagnosticLogger.append("model_catalog_loaded tool=\(tool.rawValue) catalog=\(store.summary)")
                await store.refreshIfNeeded()
            }
        }
    }

    func notifyChange() { objectWillChange.send() }

    // MARK: - Accounts

    /// The account's live state. A task still in flight for an account that
    /// was just removed gets an inert, unsaved stand-in (mode `.off`).
    func state(for tool: ProviderID) -> ToolState { accountsCoordinator.state(for: tool) }

    /// Every watched account in display order: per CLI, the default account
    /// first, then added accounts in the order they were added.
    var providers: [ProviderID] { Self.orderedProviders(accounts: accounts) }

    static func orderedProviders(accounts: [ProviderAccount]) -> [ProviderID] {
        ToolID.allCases.flatMap { kind in
            [ProviderID.default(kind)] + accounts.filter { $0.kind == kind }.map(\.providerID)
        }
    }

    typealias AccountError = AccountsCoordinator.AccountError

    @discardableResult
    func addAccount(kind: ToolID, name: String, home: String) throws -> ProviderID {
        try accountsCoordinator.addAccount(kind: kind, name: name, home: home)
    }

    func renameAccount(_ tool: ProviderID, to name: String) { accountsCoordinator.renameAccount(tool, to: name) }
    func removeAccount(_ tool: ProviderID) { accountsCoordinator.removeAccount(tool) }

    // MARK: - Per-account switches

    /// Pins/unpins a tool in the menu bar. Routed through AppState so the
    /// menu-bar label (which observes AppState, not each ToolState) refreshes
    /// immediately when toggled.
    func setMenuBarVisible(_ tool: ProviderID, _ visible: Bool) {
        objectWillChange.send()
        state(for: tool).menuBarVisible = visible
    }

    /// Flips a tool between showing quota left and quota used. Routed through
    /// AppState so the menu-bar label (which observes AppState, not each
    /// ToolState) switches its percent immediately.
    func toggleDisplayMode(for tool: ProviderID) {
        objectWillChange.send()
        let state = state(for: tool)
        state.displayMode = state.displayMode.toggled
    }

    /// Switches a tool between off / monitor-only / auto-warm. Routed through
    /// AppState (with an explicit objectWillChange) so the menu-bar label —
    /// which observes AppState, not each ToolState — refreshes immediately.
    func setMode(_ mode: ToolMode, for tool: ProviderID) {
        let state = state(for: tool)
        guard state.mode != mode else { return }
        objectWillChange.send()
        state.mode = mode

        switch mode {
        case .off:
            scheduler.invalidate(tool: tool)
            notifications.cancelAll(for: tool)
            state.claimVerifyTask?.cancel(); state.claimVerifyTask = nil
            quota.clearAuthRetry(for: state)
            state.nextRefreshAt = nil
            events.addHistory(tool: tool, kind: .quotaFetch, title: "Monitoring off", detail: "QuotaWarmer will not watch this tool")
        case .monitor:
            events.addHistory(tool: tool, kind: .quotaFetch, title: "Monitor only", detail: "Watching quota; automatic warm-up off")
            Task { await quota.refreshQuota(for: tool, allowAutomaticWarmup: false) }
        case .autoWarm:
            events.addHistory(tool: tool, kind: .quotaFetch, title: "Auto-warm on", detail: "Will claim fresh windows automatically")
            Task { await quota.refreshQuota(for: tool, allowAutomaticWarmup: true) }
        }
    }

    // MARK: - Facade over the coordinators

    var hasLivePolling: Bool { quota.hasLivePolling }
    var watcherStale: Bool { quota.watcherStale }
    var watcherStatusText: String? { quota.watcherStatusText }
    var quotaAlertSettings: QuotaAlertSettings { quota.quotaAlertSettings }

    func refreshAllActivity(allowAutomaticWarmup: Bool = false, includeInactive: Bool = false) {
        quota.refreshAllActivity(allowAutomaticWarmup: allowAutomaticWarmup, includeInactive: includeInactive)
    }

    func useResetCredit(_ credit: ResetCredit, for tool: ProviderID) async -> String? {
        await quota.useResetCredit(credit, for: tool)
    }

    func refreshQuotaManually(for tool: ProviderID) async { await quota.refreshQuotaManually(for: tool) }

    func refreshQuota(
        for tool: ProviderID,
        allowAutomaticWarmup: Bool = false,
        reconcileStuckOutcome: Bool = true,
        allowsCredentialInteraction: Bool = false,
        force: Bool = false
    ) async {
        await quota.refreshQuota(
            for: tool,
            allowAutomaticWarmup: allowAutomaticWarmup,
            reconcileStuckOutcome: reconcileStuckOutcome,
            allowsCredentialInteraction: allowsCredentialInteraction,
            force: force
        )
    }

    func activate(_ tool: ProviderID) {
        Task { await warmup.triggerWarmup(tool: tool, mode: "manual") }
    }

    @discardableResult
    func triggerWarmup(tool: ProviderID, mode: String) async -> Bool {
        await warmup.triggerWarmup(tool: tool, mode: mode)
    }

    func setMorningPrewarm(_ enabled: Bool) { morning.setMorningPrewarm(enabled) }
    func morningTimeChanged() { morning.morningTimeChanged() }

    func checkForAppUpdate() async {
        updateInfo = await updateChecker.checkForUpdate()
        events.addHistory(tool: nil, kind: .updateCheck, title: "Update checked", detail: updateInfo == nil ? "No update found" : "Update available")
    }

    // MARK: - Timers & panel

    func applyRefreshInterval() {
        startQuotaRefreshTimer()
        startUIRefreshTimer()
        quota.applyRefreshIntervalToStates()
    }

    private func startQuotaRefreshTimer() {
        quotaTimer?.invalidate()
        quotaTimer = Timer.scheduledTimer(withTimeInterval: settings.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllActivity(allowAutomaticWarmup: true)
            }
            // Throttled to one GitHub fetch per day inside each store.
            Task.detached(priority: .utility) {
                for tool in ToolID.allCases { await ModelCatalogStore.shared(for: tool).refreshIfNeeded() }
            }
        }
    }

    private func startUIRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Countdowns only need a full SwiftUI pass while the panel is on
                // screen. Closed (most of the time), just re-check the menu-bar
                // label, which redraws only when its text or status changes.
                if self.isPanelVisible {
                    self.toolStates.values.forEach { $0.objectWillChange.send() }
                    self.objectWillChange.send()
                } else {
                    self.onUITick?()
                }
            }
        }
    }

    /// Set by AppDelegate while the panel is shown; gates the per-second
    /// SwiftUI invalidation above.
    var isPanelVisible = false
    /// Natural height of the visible tab's content (0 when the tab doesn't report one).
    @Published var panelContentHeight: CGFloat = 0

    static func panelHeight(forMeasured measured: CGFloat) -> CGFloat {
        measured > 0 ? min(max(measured, 300), maxPanelHeight) : DS.totalHeight
    }

    /// Tallest unscaled panel that still fits under the menu bar on the
    /// current screen (with a small margin), so a long tab such as History is
    /// shown whole instead of being clipped at a fixed cap.
    static var maxPanelHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 800
        return max(400, (visible - 24) / DS.panelScale)
    }
    /// Menu-bar refresh for the 1 s tick while the panel is closed.
    var onUITick: (() -> Void)?

    // MARK: - Onboarding

    private func checkOnboarding() async {
        var anyMissing = false
        for tool in ToolID.allCases {
            if await runner.cliMissing(tool) { anyMissing = true }
        }
        let decision = OnboardingFlow.launchDecision(
            completedVersion: settings.onboardingCompletedVersion,
            hadPriorSettings: hadPriorSettings,
            anyCLIMissing: anyMissing,
            bannerDismissed: settings.onboardingDismissed)
        if decision.markCompleted { settings.onboardingCompletedVersion = OnboardingFlow.currentVersion }
        if decision.showGuide { openWelcomeGuide() }
        if decision.showMissingCLIBanner { showOnboarding = true }
    }

    /// First launch, and Settings → "Show Welcome Guide".
    func openWelcomeGuide() {
        showWelcomeGuide = true
        selectedTab = .main
    }

    func finishWelcomeGuide() {
        settings.onboardingCompletedVersion = OnboardingFlow.currentVersion
        showWelcomeGuide = false
    }
}
