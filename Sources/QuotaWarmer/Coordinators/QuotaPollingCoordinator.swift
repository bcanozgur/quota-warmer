import Foundation

/// Quota polling: fetching snapshots, applying them (or the error) to the
/// per-account `ToolState`, rate-limit backoff, the bounded Claude auth
/// recheck (15/45/90 s), the liveness watchdog, the `status.json` export,
/// threshold alerts and the throttled local token-usage scan.
///
/// The reset decision is made only from fresh snapshots produced here; local
/// CLI logs are display context and never trigger a warm-up.
@MainActor
final class QuotaPollingCoordinator {
    private unowned let host: CoordinatorHost
    private let quotaProvider: QuotaProviding
    private let runner: WarmupRunner
    private let scheduler: Scheduler
    private let notifications: NotificationManager

    /// One long-lived scanner per tool: each caches parsed log files and only
    /// reads what was appended since its last scan.
    private var usageProviders: [ProviderID: LocalUsageProvider] = [:]
    private var tokenUsageScannedAt: [ProviderID: Date] = [:]
    /// Quota refreshes come in bursts (warm-up verification, settle re-polls,
    /// wake); token totals need not follow each one.
    private let tokenUsageMinInterval: TimeInterval = 60
    private let claudeAuthRetryDelays: [TimeInterval] = [15, 45, 90]

    init(
        host: CoordinatorHost, quotaProvider: QuotaProviding, runner: WarmupRunner,
        scheduler: Scheduler, notifications: NotificationManager
    ) {
        self.host = host
        self.quotaProvider = quotaProvider
        self.runner = runner
        self.scheduler = scheduler
        self.notifications = notifications
    }

    private var refreshInterval: TimeInterval { host.settings.refreshInterval }

    // MARK: - Watchdog

    /// Whether anything is being polled right now (drives the watchdog).
    var hasLivePolling: Bool {
        !host.globalPassive && host.providers.contains { host.state(for: $0).isMonitored }
    }

    /// True when the app should be polling but hasn't had a successful quota
    /// fetch in a suspiciously long time — i.e. it may be silently stalled.
    var watcherStale: Bool {
        guard hasLivePolling, let last = host.lastSuccessfulPollAt else { return false }
        return Date().timeIntervalSince(last) > max(refreshInterval * 2, 120)
    }

    /// User-facing one-liner for the watchdog, or nil when healthy.
    var watcherStatusText: String? {
        guard watcherStale, let last = host.lastSuccessfulPollAt else { return nil }
        let minutes = max(1, Int(Date().timeIntervalSince(last) / 60))
        return String(localized: "No successful check in \(minutes)m")
    }

    // MARK: - Status export

    /// Rewrites `status.json` (see `QuotaStatusExport`) from every watched
    /// account's latest snapshot, for the statusline script and other tools.
    func exportStatus() {
        let entries = host.providers.compactMap { provider -> QuotaStatusExport.Entry? in
            guard let state = host.toolStates[provider] else { return nil }
            return QuotaStatusExport.Entry(
                provider: state.tool,
                mode: state.mode,
                displayMode: state.displayMode,
                pinned: state.menuBarVisible,
                snapshot: state.quotaSnapshot
            )
        }
        QuotaStatusExport.write(QuotaStatusExport.make(entries))
    }

    // MARK: - Refresh entry points

    func refreshAllActivity(allowAutomaticWarmup: Bool = false, includeInactive: Bool = false) {
        host.isRefreshing = true
        let tools = host.providers.filter { includeInactive || host.state(for: $0).isMonitored }
        guard !tools.isEmpty else {
            host.isRefreshing = false
            return
        }
        for tool in tools {
            Task { await refreshQuota(for: tool, allowAutomaticWarmup: allowAutomaticWarmup) }
        }
        Task { @MainActor [host] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            host.isRefreshing = false
        }
    }

    /// Redeems a banked Codex reset, then force-refreshes so the bars show the
    /// restored quota. Returns a user-facing error, or nil on success.
    func useResetCredit(_ credit: ResetCredit, for tool: ProviderID) async -> String? {
        do {
            let windows = try await quotaProvider.consumeCodexResetCredit(id: credit.id, provider: tool)
            host.events.addHistory(tool: tool, kind: .quotaFetch, title: "Banked reset used",
                                   detail: "\(credit.title); \(windows) window(s) reset")
            await refreshQuotaManually(for: tool)
            return nil
        } catch let error as QuotaProviderError {
            return error.errorDescription ?? String(localized: "Could not use the reset.")
        } catch {
            return String(localized: "Could not use the reset.")
        }
    }

    /// The Refresh button. Unlike a timer poll this must always do something the
    /// user can see: it ignores an outstanding rate-limit backoff (which would
    /// otherwise leave the button a silent no-op for the whole retry window) and
    /// may show the Keychain approval dialog, because a click is the one moment
    /// interaction is wanted. An opted-in auto-warm still resumes here, bounded
    /// to once per window by the usual dedup, so approving access mid-window
    /// claims it instead of waiting for the next tick.
    func refreshQuotaManually(for tool: ProviderID) async {
        let shouldAutoWarm = tool.kind == .claude && host.state(for: tool).isAutoWarmEnabled
        await refreshQuota(
            for: tool,
            allowAutomaticWarmup: shouldAutoWarm,
            allowsCredentialInteraction: tool.kind == .claude,
            force: true
        )
    }

    func refreshQuota(
        for tool: ProviderID,
        allowAutomaticWarmup: Bool = false,
        reconcileStuckOutcome: Bool = true,
        allowsCredentialInteraction: Bool = false,
        force: Bool = false
    ) async {
        let state = host.state(for: tool)
        // Timer, wake and scheduler callbacks can converge on the same instant.
        // Claude refresh tokens are single-use, so only one Claude request chain
        // may run at a time. Codex keeps its existing behavior unchanged.
        guard tool.kind != .claude || !state.isFetchingQuota else { return }
        refreshTokenUsage(for: tool, force: force)
        if let backoffUntil = state.quotaBackoffUntil, backoffUntil > Date() {
            // An explicit user request retries now. Clearing the backoff matters
            // as much as skipping it: a source that is no longer limited must be
            // able to return to healthy instead of staying pinned to the stale
            // reading until the original retry time.
            if force {
                clearQuotaBackoff(for: state)
            } else {
                state.nextRefreshAt = backoffUntil
                state.errorMessage = rateLimitMessage(until: backoffUntil)
                state.healthMessage = state.errorMessage ?? state.healthMessage
                scheduleQuotaRefresh(for: tool, at: backoffUntil)
                return
            }
        }

        state.isFetchingQuota = true
        state.errorMessage = nil

        do {
            let snapshot = try await quotaProvider.fetchQuota(
                for: tool,
                allowsCredentialInteraction: allowsCredentialInteraction
            )
            clearQuotaBackoff(for: state)
            clearAuthRetry(for: state)
            host.lastSuccessfulPollAt = Date()
            state.quotaSnapshot = snapshot
            // Removed mid-fetch: don't recreate the deleted history file.
            if host.toolStates[tool] != nil {
                UsageHistoryStore.shared.record(snapshot, for: tool)
                evaluateQuotaAlerts(for: tool, snapshot: snapshot)
            }
            exportStatus()
            state.sourceHealth = snapshot.freshness() == .fresh ? .healthy : .stale
            state.authStatus = .available
            state.healthMessage = snapshot.message ?? snapshot.primarySource
            state.nextRefreshAt = Date().addingTimeInterval(refreshInterval)
            state.clearConfirmedWarmupIfLiveResetExistsOrExpired()
            // Background self-heal of a stuck warm-up status. Skipped while a
            // warm-up is in flight, and skipped on the recheck path (which calls
            // evaluateWarmupClaim right after) so the two never both confirm.
            if reconcileStuckOutcome, !state.isWarming { host.warmup.reconcileWarmupOutcome(for: state) }
            host.events.addHistory(
                tool: tool,
                kind: .quotaFetch,
                title: "Quota fetched",
                detail: quotaFetchDetail(snapshot)
            )
            rescheduleRefresh(for: tool)

            // A successful OAuth quota response is stronger evidence than the
            // headless `claude auth status` probe, which can report logged-out
            // even while the real Claude CLI and OAuth credential are usable.
            // The actual warm-up command still reports authentication failure.
            if allowAutomaticWarmup {
                // Claude serializes quota fetches. Release the outer fetch before
                // the warm-up path performs its post-command verification fetch;
                // otherwise the single-flight guard would discard that proof.
                if tool.kind == .claude { state.isFetchingQuota = false }
                await host.warmup.attemptAutomaticWarmup(tool: tool, reason: "fresh quota")
            }
        } catch {
            applyQuotaError(error, to: state)
        }

        state.isFetchingQuota = false
    }

    // MARK: - Alerts

    /// Settings → Alerts (session/weekly used% thresholds, pace warning).
    var quotaAlertSettings: QuotaAlertSettings { QuotaAlertSettings.load() }

    /// Posts any session/weekly/pace warning a fresh snapshot makes due, each at
    /// most once per window (see `QuotaAlertPolicy`). Silent while paused.
    private func evaluateQuotaAlerts(for tool: ProviderID, snapshot: QuotaSnapshot) {
        guard !host.globalPassive else { return }
        let marks = QuotaAlertMark.load(storageKey: tool.storageKey)
        let evaluation = QuotaAlertPolicy.evaluate(
            snapshot: snapshot,
            settings: quotaAlertSettings,
            marks: marks,
            fiveHourDuration: tool.windowDuration,
            weeklyDuration: tool.weeklyWindowDuration
        )
        if evaluation.marks != marks {
            QuotaAlertMark.save(evaluation.marks, storageKey: tool.storageKey)
        }
        for alert in evaluation.alerts {
            notifications.notifyQuotaAlert(alert, tool: tool)
            DiagnosticLogger.append("quota_alert tool=\(tool.rawValue) kind=\(alert.kind.rawValue) used=\(alert.usedPercent)")
        }
    }

    // MARK: - Token usage

    private func usageProvider(for tool: ProviderID) -> LocalUsageProvider {
        if let existing = usageProviders[tool] { return existing }
        let created = LocalUsageProvider()
        usageProviders[tool] = created
        return created
    }

    /// Drops the scanner state of a removed account.
    func forgetTokenUsage(for tool: ProviderID) {
        usageProviders[tool] = nil
        tokenUsageScannedAt[tool] = nil
    }

    private func refreshTokenUsage(for tool: ProviderID, force: Bool = false) {
        let state = host.state(for: tool)
        // Skip if a scan is already in flight for this tool — otherwise rapid
        // refresh cycles can pile up overlapping disk scans. This single-flight
        // is also what makes sharing one provider per tool safe.
        guard !state.isFetchingTokenUsage else { return }
        let provider = usageProvider(for: tool)
        if !force, let last = tokenUsageScannedAt[tool], Date().timeIntervalSince(last) < tokenUsageMinInterval {
            return
        }
        tokenUsageScannedAt[tool] = Date()
        state.isFetchingTokenUsage = true
        // The scan walks the CLI JSONL logs synchronously; keep it off the main
        // actor so the menu-bar panel never freezes (which also kept it from
        // dismissing on outside clicks).
        Task.detached(priority: .utility) {
            let summary = provider.usage(for: tool.kind, baseURL: tool.logDirectoryURL)
            await MainActor.run {
                state.tokenUsageSummary = summary
                state.isFetchingTokenUsage = false
            }
        }
    }

    // MARK: - Scheduling

    func applyRefreshIntervalToStates() {
        for tool in host.providers where host.state(for: tool).isMonitored {
            host.state(for: tool).nextRefreshAt = Date().addingTimeInterval(refreshInterval)
        }
    }

    func scheduleQuotaRefresh(for tool: ProviderID, at date: Date) {
        guard host.state(for: tool).isMonitored, !host.globalPassive else { return }
        scheduler.schedule(tool: tool, at: date)
    }

    private func rescheduleRefresh(for tool: ProviderID) {
        let state = host.state(for: tool)
        guard state.isMonitored, !host.globalPassive else {
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

    // MARK: - Errors, backoff, auth recheck

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

    func clearAuthRetry(for state: ToolState) {
        state.authRetryTask?.cancel()
        state.authRetryTask = nil
        state.authRetryAttempts = 0
        state.authRetryScheduledAt = nil
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
            case .credentialInteractionRequired:
                clearQuotaBackoff(for: state)
                clearAuthRetry(for: state)
                state.sourceHealth = .authFailure
                state.authStatus = .missing
                host.events.addHistory(tool: state.tool, kind: .authFailure, title: "Claude access needs approval", detail: message)
            case .cliRefreshRequired:
                clearQuotaBackoff(for: state)
                clearAuthRetry(for: state)
                state.errorMessage = nil
                state.healthMessage = message
                state.sourceHealth = .stale
                state.authStatus = .available
                host.events.addHistory(tool: state.tool, kind: .quotaFetch, title: "Claude CLI refresh needed", detail: message)
            case .authFailure:
                clearQuotaBackoff(for: state)
                clearAuthRetry(for: state)
                state.sourceHealth = .authFailure
                state.authStatus = .failed
                host.events.addHistory(tool: state.tool, kind: .authFailure, title: "Authorization failed", detail: message)
            case .missingCredentials:
                clearQuotaBackoff(for: state)
                state.sourceHealth = .authFailure
                state.authStatus = .missing
                host.events.addHistory(tool: state.tool, kind: .authFailure, title: "Credentials missing", detail: message)
                scheduleClaudeAuthRecheckIfNeeded(for: state, reason: message)
            case .rateLimited(_, let retryAfter):
                clearAuthRetry(for: state)
                let retryAt = applyQuotaBackoff(for: state, retryAfter: retryAfter)
                let retryMessage = rateLimitMessage(until: retryAt)
                state.sourceHealth = .rateLimited
                state.authStatus = .available
                state.errorMessage = retryMessage
                state.healthMessage = retryMessage
                host.events.addHistory(tool: state.tool, kind: .rateLimit, title: "Rate limited", detail: "\(message). Retrying at \(shortTime(retryAt)).")
            case .unavailable, .malformed:
                clearQuotaBackoff(for: state)
                clearAuthRetry(for: state)
                state.sourceHealth = state.quotaSnapshot == nil ? .unavailable : .stale
                host.events.addHistory(tool: state.tool, kind: .pollingError, title: "Quota fetch failed", detail: message)
            }
        } else {
            clearQuotaBackoff(for: state)
            clearAuthRetry(for: state)
            state.sourceHealth = state.quotaSnapshot == nil ? .unavailable : .stale
            host.events.addHistory(tool: state.tool, kind: .pollingError, title: "Quota fetch failed", detail: message)
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

    private func applyCLIAuthenticationStatusIfNeeded(for tool: ProviderID, to state: ToolState) async -> Bool {
        guard tool.kind == .claude else { return true }

        switch await runner.cliAuthenticationStatus(for: tool) {
        case .authenticated:
            if state.authStatus == .failed || state.authStatus == .missing {
                host.events.addHistory(tool: tool, kind: .quotaFetch, title: "Claude CLI auth restored", detail: "Warmup can run again")
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
                host.events.addHistory(tool: tool, kind: .authFailure, title: "Claude CLI login required", detail: message)
            }
            scheduleClaudeAuthRecheckIfNeeded(for: state, reason: message)
            return false
        case .unknown(let message):
            DiagnosticLogger.append("cli_auth_status_unknown tool=\(tool.rawValue) reason=\(message)")
            return true
        }
    }

    /// Claude quota auth failures schedule short automatic rechecks (15 s, 45 s,
    /// 90 s) so a just-completed `claude auth login` can recover without waiting
    /// for the normal timer. Bounded: it stops after the last delay.
    func scheduleClaudeAuthRecheckIfNeeded(for state: ToolState, reason: String) {
        guard state.tool.kind == .claude, state.isMonitored, !host.globalPassive else { return }
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

        host.events.addHistory(
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
            await self?.runClaudeAuthRecheck(for: state.tool, attempt: attempt)
        }
    }

    private func runClaudeAuthRecheck(for tool: ProviderID, attempt: Int) async {
        guard let state = host.toolStates[tool] else { return }
        guard state.authRetryAttempts == attempt else { return }
        state.authRetryTask = nil
        state.authRetryScheduledAt = nil
        DiagnosticLogger.append("auth_recheck_running tool=\(tool.rawValue) attempt=\(attempt)")
        guard await applyCLIAuthenticationStatusIfNeeded(for: tool, to: state) else { return }
        await refreshQuota(for: tool, allowAutomaticWarmup: false)
    }
}
