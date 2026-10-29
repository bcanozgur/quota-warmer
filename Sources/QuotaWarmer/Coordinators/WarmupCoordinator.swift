import Foundation

/// Warm-up execution: the manual/auto/scheduled command run, the automatic
/// decision call sites (`AutoWarmDecision` gate + window), the window-claim
/// receipt (confirm / bounded re-check / unverified), settle re-polls and
/// failed-warm-up backoff.
@MainActor
final class WarmupCoordinator {
    private unowned let host: CoordinatorHost
    private let runner: WarmupRunner
    private let notifications: NotificationManager

    init(host: CoordinatorHost, runner: WarmupRunner, notifications: NotificationManager) {
        self.host = host
        self.runner = runner
        self.notifications = notifications
    }

    func attemptAutomaticWarmup(tool: ProviderID, reason: String) async {
        let state = host.state(for: tool)
        let gate = managedWarmupGate(for: tool)
        guard gate == .warm else {
            noteAutoWarmDecision(state, gate)
            return
        }

        await refreshQuotaForAutomaticDecision(tool: tool)
        let now = Date()
        let decision = AutoWarmDecision.window(
            AutoWarmDecision.Window(
                sourceHealth: state.sourceHealth,
                snapshot: state.quotaSnapshot,
                windowDuration: tool.windowDuration,
                lastAutoWindowKey: state.lastAutoWindowKey,
                lastAutoWarmWindowEndsAt: state.lastAutoWarmWindowEndsAt,
                upcomingMorningAt: host.morning.upcomingReservedMorningDate(now: now),
                awaitingCLITokenRefresh: state.awaitingCLITokenRefresh
            ),
            now: now
        )
        noteAutoWarmDecision(state, decision)
        guard decision == .warm, let snapshot = state.quotaSnapshot else {
            switch decision.skipReason {
            case .reservedForMorning(let scheduledAt):
                DiagnosticLogger.append(
                    "auto_warm_reserved_for_morning tool=\(tool.rawValue) scheduledAt=\(ISO8601DateFormatter().string(from: scheduledAt))"
                )
            case .warmedWindowActive(let endsAt):
                DiagnosticLogger.append("auto_warm_skipped_active_window tool=\(tool.rawValue) windowEndsAt=\(ISO8601DateFormatter().string(from: endsAt))")
            default:
                break
            }
            return
        }

        host.events.addHistory(tool: tool, kind: .resetDetected, title: "Fresh reset detected", detail: reason)
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

    func managedWarmupGate(for tool: ProviderID) -> AutoWarmDecision {
        let state = host.state(for: tool)
        return AutoWarmDecision.gate(
            AutoWarmDecision.Gate(
                isAutoWarmEnabled: state.isAutoWarmEnabled,
                globalPassive: host.globalPassive,
                isWarming: state.isWarming,
                authStatus: state.authStatus,
                rateLimitGuard: host.settings.rateLimitGuard,
                backoffUntil: state.backoffUntil
            ),
            now: Date()
        )
    }

    func claimAutoWindowFromPostWarmQuota(for tool: ProviderID, previousFetchedAt: Date?) {
        let state = host.state(for: tool)
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

    func refreshQuotaForAutomaticDecision(tool: ProviderID) async {
        let state = host.state(for: tool)
        if state.freshness == .fresh, state.sourceHealth != .rateLimited { return }
        await host.quota.refreshQuota(for: tool, allowAutomaticWarmup: false)
    }

    @discardableResult
    func triggerWarmup(tool: ProviderID, mode: String) async -> Bool {
        let state = host.state(for: tool)
        guard !state.isWarming else { return false }

        state.isWarming = true
        state.errorMessage = nil
        // Any warm-up (auto, morning, manual) can start inside a DarkWake; hold
        // the Mac awake until the command and the immediate quota re-check end.
        let sleepGuard = SleepGuard(reason: "warmup-\(tool.rawValue)-\(mode)")
        defer { sleepGuard.release() }
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
            host.events.addHistory(
                tool: tool,
                kind: historyKind(forWarmupMode: mode),
                title: historyTitle(forWarmupMode: mode),
                detail: "Command completed",
                outcome: .sent,
                model: WarmupRunner.modelArgument(in: result.command),
                source: WarmupSource(mode: mode)
            )
            state.lastWarmupModel = WarmupRunner.modelArgument(in: result.command)
            notifications.notifyWarmupCommandSent(tool: tool)
            state.lastWarmupOutcome = .pending(sentAt: result.date)
            await host.quota.refreshQuota(
                for: tool,
                allowAutomaticWarmup: false
            )
            // No *real* live window yet: either no reset at all, or only an idle
            // "if you started now" projection (Claude's null `five_hour` is now
            // surfaced as an idle window with a sliding reset). Record the
            // command's expected reset so the confirm path (evaluateWarmupClaim)
            // has a stable boundary to trust instead of the sliding projection.
            // A reset already in the past means the re-check still failed (e.g. an
            // expired Claude token) and only the old window's reading is left.
            let liveMetric = state.primaryMetric
            let liveResetPassed = liveMetric?.resetAt.map { $0 <= result.date } ?? false
            if liveMetric?.resetAt == nil || liveMetric?.isIdle == true || liveResetPassed {
                state.rememberConfirmedWarmup(startedAt: result.date, duration: tool.windowDuration)
            }
            // Remember when this freshly-claimed window resets so the auto path
            // won't re-warm it on the next poll (see attemptAutomaticWarmup). A
            // past reset would leave the guard open and re-warm every poll.
            let windowEnd = state.resetAt.flatMap { $0 > result.date ? $0 : nil }
                ?? result.date.addingTimeInterval(tool.windowDuration)
            state.rememberAutoWarmWindowEnd(windowEnd)
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
            host.events.addHistory(tool: tool, kind: .authFailure, title: "Warmup blocked", detail: message, outcome: .failed)
            host.quota.scheduleClaudeAuthRecheckIfNeeded(for: state, reason: message)
        } catch {
            state.errorMessage = error.localizedDescription
            state.backoffUntil = Date().addingTimeInterval(nextBackoff(for: state))
            state.lastWarmupOutcome = .failed(at: Date(), reason: error.localizedDescription)
            host.events.addHistory(tool: tool, kind: .pollingError, title: "Warmup failed", detail: error.localizedDescription, outcome: .failed)
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
    func evaluateWarmupClaim(for tool: ProviderID, sentAt: Date, attempt: Int) {
        let state = host.state(for: tool)
        if state.quotaSnapshot?.showsActiveWindow() == true {
            state.claimVerifyTask?.cancel(); state.claimVerifyTask = nil
            state.lastWarmupOutcome = .confirmed(at: Date(), resetAt: state.resetAt)
            let fields = claimFields(state)
            host.events.addHistory(
                tool: tool, kind: .resetDetected, title: "Window claim confirmed", detail: claimConfirmedDetail(state),
                outcome: .confirmed, windowKey: fields.windowKey, windowResetAt: fields.windowResetAt, model: fields.model
            )
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
            let expectedReset = state.confirmedWarmupResetAt ?? state.resetAt
            state.lastWarmupOutcome = .unverified(sentAt: sentAt, expectedResetAt: expectedReset)
            host.events.addHistory(
                tool: tool,
                kind: .pollingError,
                title: "Window claim unverified",
                detail: "The command completed, but live quota did not confirm an active window.",
                outcome: .missed,
                windowResetAt: expectedReset,
                model: state.lastWarmupModel
            )
            DiagnosticLogger.append("warmup_claim_unverified tool=\(tool.rawValue)")
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
    func reconcileWarmupOutcome(for state: ToolState) {
        switch state.lastWarmupOutcome {
        case .pending(let sentAt):
            if state.quotaSnapshot?.showsActiveWindow() == true {
                state.claimVerifyTask?.cancel(); state.claimVerifyTask = nil
                state.lastWarmupOutcome = .confirmed(at: Date(), resetAt: state.resetAt)
                let fields = claimFields(state)
                host.events.addHistory(
                    tool: state.tool, kind: .resetDetected, title: "Window claim confirmed", detail: claimConfirmedDetail(state),
                    outcome: .confirmed, windowKey: fields.windowKey, windowResetAt: fields.windowResetAt, model: fields.model
                )
                DiagnosticLogger.append("warmup_claim_healed tool=\(state.tool.rawValue)")
            } else if Date().timeIntervalSince(sentAt) > state.tool.windowDuration {
                state.lastWarmupOutcome = .none
            }
        case .confirmed(_, let resetAt):
            // The claimed window has fully reset (its boundary is in the past) and
            // the live snapshot no longer shows an active window — clear the
            // "Window claimed at …" card so it doesn't keep implying an active
            // window hours after that window expired.
            if let resetAt, resetAt <= Date(),
               state.quotaSnapshot?.showsActiveWindow() != true {
                state.lastWarmupOutcome = .none
            }
        case .unverified(_, let expectedResetAt):
            if state.quotaSnapshot?.showsActiveWindow() == true {
                state.lastWarmupOutcome = .confirmed(at: Date(), resetAt: state.resetAt)
                let fields = claimFields(state)
                host.events.addHistory(
                    tool: state.tool, kind: .resetDetected, title: "Window claim confirmed", detail: claimConfirmedDetail(state),
                    outcome: .confirmed, windowKey: fields.windowKey, windowResetAt: fields.windowResetAt, model: fields.model
                )
                DiagnosticLogger.append("warmup_claim_healed tool=\(state.tool.rawValue)")
            } else if let expectedResetAt, expectedResetAt <= Date() {
                state.lastWarmupOutcome = .none
            }
        default:
            break
        }
    }

    func runClaimVerification(tool: ProviderID, sentAt: Date, attempt: Int) async {
        let state = host.state(for: tool)
        guard state.claimVerifyTask != nil else { return }
        state.claimVerifyTask = nil
        await host.quota.refreshQuota(for: tool, allowAutomaticWarmup: false, reconcileStuckOutcome: false)
        evaluateWarmupClaim(for: tool, sentAt: sentAt, attempt: attempt)
    }

    /// Short, bounded follow-up polls that run only while the live 5h reading is
    /// an unsettled rollover artifact (`sessionSettling`). Stops as soon as the
    /// provider returns the real percentage, or after the last delay. Distinct
    /// from `claimVerifyTask` (which proves the *window* opened, and stops on
    /// confirmation) — this exists purely to settle the displayed *quota*.
    private let settleRepollDelays: [TimeInterval] = [20, 45, 90]

    func scheduleSettleRepoll(for tool: ProviderID, attempt: Int = 0) {
        let state = host.state(for: tool)
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
            await self?.host.quota.refreshQuota(for: tool, allowAutomaticWarmup: false, reconcileStuckOutcome: false)
            self?.scheduleSettleRepoll(for: tool, attempt: attempt + 1)
        }
    }

    func claimConfirmedDetail(_ state: ToolState) -> String {
        guard let reset = state.resetAt else { return "Window is active." }
        let seconds = max(0, Int(reset.timeIntervalSinceNow))
        return "Window active · resets in \(seconds / 3600)h \((seconds % 3600) / 60)m"
    }

    func historyKind(forWarmupMode mode: String) -> HistoryKind {
        switch mode {
        case "auto", "scheduled", "scheduled-catchup":
            return .autoWarmup
        default:
            return .manualWarmup
        }
    }

    func historyTitle(forWarmupMode mode: String) -> String {
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

    /// Records the decision on the tool and, only when the skip reason changed
    /// to a user-relevant one, a single history event (not one per poll).
    func noteAutoWarmDecision(_ state: ToolState, _ decision: AutoWarmDecision) {
        let previous = state.recordAutoWarmDecision(decision)
        if let entry = AutoWarmExplanation.historyEntry(previous: previous, new: decision.skipReason, now: Date()) {
            host.events.addHistory(tool: state.tool, kind: .autoWarmup, title: entry.title, detail: entry.detail, outcome: .skipped, source: .auto)
        }
    }

    /// Structured fields shared by the claim receipt events.
    func claimFields(_ state: ToolState) -> (windowKey: String?, windowResetAt: Date?, model: String?) {
        (state.quotaSnapshot?.rawWindowKey, state.resetAt, state.lastWarmupModel)
    }

    func nextBackoff(for state: ToolState) -> TimeInterval {
        if let backoffUntil = state.backoffUntil, backoffUntil > Date() {
            return min(backoffUntil.timeIntervalSinceNow * 2, 30 * 60)
        }
        return 5 * 60
    }
}
