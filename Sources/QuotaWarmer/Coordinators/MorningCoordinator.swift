import Foundation

/// Morning pre-warm: the in-app timer, the system-wake handler and the
/// `pmset` wake schedule (via `WakeScheduler`). A scheduled warm-up is deduped
/// to once per calendar day per account (`lastMorningWarmDay`) and is routed
/// through `runScheduledMorningWarmupIfNeeded` from both the timer and wake.
/// The enabled flag and status text are `@Published` on `AppState`.
@MainActor
final class MorningCoordinator {
    private unowned let host: CoordinatorHost
    private let scheduler: Scheduler
    private let wakeScheduler = WakeScheduler()
    private var morningReapplyTask: Task<Void, Never>?

    init(host: CoordinatorHost, scheduler: Scheduler) {
        self.host = host
        self.scheduler = scheduler
    }


    /// Toggle entry point from Settings. Enabling/disabling touches the system
    /// power schedule via a single admin prompt.
    func setMorningPrewarm(_ enabled: Bool) {
        guard enabled != host.morningPrewarmEnabled else { return }
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
        guard host.morningPrewarmEnabled else { return }
        scheduleMorningTimer()
        morningReapplyTask?.cancel()
        morningReapplyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard !Task.isCancelled else { return }
            await self?.applyHardwareWake()
        }
    }

    func enableMorningPrewarm() async {
        host.morningPrewarmEnabled = true
        host.settings.morningPrewarmEnabled = true
        let ok = await applyHardwareWake()
        if ok {
            scheduleMorningTimer()
        } else {
            // Admin cancelled / failed — revert so the UI reflects reality.
            host.morningPrewarmEnabled = false
            host.settings.morningPrewarmEnabled = false
            scheduler.cancelMorning()
        }
    }

    func disableMorningPrewarm() async {
        host.morningPrewarmEnabled = false
        host.settings.morningPrewarmEnabled = false
        scheduler.cancelMorning()
        morningReapplyTask?.cancel()
        let result = await wakeScheduler.cancel()
        host.morningStatus = result.success ? String(localized: "Morning pre-warm is off.") : result.message
        host.events.addHistory(tool: nil, kind: .quotaFetch, title: "Morning pre-warm off", detail: result.message)
    }

    @discardableResult
    func applyHardwareWake() async -> Bool {
        let days: WakeScheduler.WakeDays = host.settings.morningWeekdaysOnly ? .weekdays : .everyday
        let result = await wakeScheduler.apply(hour: host.settings.morningHour, minute: host.settings.morningMinute, days: days)
        if result.success {
            let timeText = String(format: "%02d:%02d", host.settings.morningHour, host.settings.morningMinute)
            if WakeScheduler.isOnACPower() {
                host.morningStatus = String(localized: "Mac will wake at \(timeText) and start your window.")
            } else {
                host.morningStatus = String(localized: "Scheduled for \(timeText), but on battery with the lid closed the wake may be skipped — your window warms the moment you open the lid.")
            }
            host.events.addHistory(tool: nil, kind: .quotaFetch, title: "Morning pre-warm scheduled", detail: result.message)
        } else {
            host.morningStatus = result.message
        }
        return result.success
    }

    func refreshMorningHardwareStatus() {
        let days: WakeScheduler.WakeDays = host.settings.morningWeekdaysOnly ? .weekdays : .everyday
        guard wakeScheduler.scheduleMatches(hour: host.settings.morningHour, minute: host.settings.morningMinute, days: days) else {
            let expectedTime = String(format: "%02d:%02d", host.settings.morningHour, host.settings.morningMinute)
            host.morningStatus = String(localized: "Morning wake is not installed or was replaced. Toggle Wake & Warm off and on to repair it.")
            DiagnosticLogger.append("morning_wake_schedule_mismatch expected=\(expectedTime) days=\(days.humanLabel)")
            return
        }
        let timeText = String(format: "%02d:%02d", host.settings.morningHour, host.settings.morningMinute)
        host.morningStatus = WakeScheduler.isOnACPower()
            ? String(localized: "Mac will wake at \(timeText) and start your window.")
            : String(localized: "Scheduled for \(timeText); battery and a closed lid can prevent the wake.")
    }

    func scheduleMorningTimer() {
        scheduler.cancelMorning()
        guard host.morningPrewarmEnabled, let fireDate = nextMorningFireDate() else { return }
        DiagnosticLogger.append("morning_timer_scheduled fireAt=\(ISO8601DateFormatter().string(from: fireDate))")
        scheduler.scheduleMorning(at: fireDate) { [weak self] sleepGuard in
            Task { @MainActor [weak self] in
                defer { sleepGuard.release() }
                await self?.runScheduledMorningWarmupIfNeeded(source: .timer)
            }
        }
    }

    enum ScheduledMorningSource {
        case timer
        case wake
        case launch
    }

    /// Scheduled pre-warm is intentionally separate from fresh-reset detection:
    /// it may start a not-yet-active window after a missed launch/wake, so it
    /// must not depend on `resetAt` being present in quota API payloads.
    func runScheduledMorningWarmupIfNeeded(source: ScheduledMorningSource) async {
        guard host.morningPrewarmEnabled, !host.globalPassive else { scheduleMorningTimer(); return }

        let now = Date()
        let todayKey = Self.dayKey(now)
        if host.settings.morningWeekdaysOnly, Calendar.current.isDateInWeekend(now) {
            scheduleMorningTimer(); return
        }

        guard let scheduledAt = todaysMorningDate(now: now) else {
            scheduleMorningTimer(); return
        }

        guard now >= scheduledAt else {
            scheduleMorningTimer(); return
        }

        // A pmset wake may be a short DarkWake. Keep the Mac awake only while
        // the scheduled quota check and bounded warm-up command are running so
        // the system cannot return to sleep halfway through the claim.
        let scheduledActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "QuotaWarmer scheduled morning warm-up"
        )
        defer { ProcessInfo.processInfo.endActivity(scheduledActivity) }
        let sleepGuard = SleepGuard(reason: "morning-\(String(describing: source))")
        defer { sleepGuard.release() }
        DiagnosticLogger.append("morning_warm_running source=\(String(describing: source))")

        var caughtUpSuccessfully = false
        for tool in host.providers where host.state(for: tool).isAutoWarmEnabled {
            let state = host.state(for: tool)
            let gate = host.warmup.managedWarmupGate(for: tool)
            guard gate == .warm else {
                host.warmup.noteAutoWarmDecision(state, gate)
                logMorningSkip(tool: tool, reason: "managedWarmupBlocked", source: source)
                continue
            }

            // Scheduled warm-up is still an automatic action: require a fresh,
            // healthy provider snapshot. Local CLI logs are display context only.
            await host.quota.refreshQuota(
                for: tool,
                allowAutomaticWarmup: false
            )
            let sourceFresh = state.sourceHealth == .healthy && state.freshness == .fresh
            let liveWindowActive = state.quotaSnapshot?.showsActiveWindow() == true
            // An overnight token expiry would otherwise skip every morning: the
            // warm-up's CLI run is what refreshes the token.
            let expiredCredentialWindowEnded = state.awaitingCLITokenRefresh
                && state.quotaSnapshot?.lastKnownWindowEnded() == true
            let decision = MorningWarmupPolicy.decision(
                now: now,
                scheduledAt: scheduledAt,
                dayKey: todayKey,
                lastSuccessfulDay: lastMorningWarmDay(for: tool, todayKey: todayKey),
                liveWindowActive: liveWindowActive,
                sourceFresh: sourceFresh,
                expiredCredentialWindowEnded: expiredCredentialWindowEnded,
                windowDuration: tool.windowDuration
            )

            guard case .run(let caughtUp) = decision else {
                if case .skip(let reason) = decision {
                    host.warmup.noteAutoWarmDecision(state, .skip(.morning(reason)))
                    logMorningSkip(tool: tool, reason: reason.rawValue, source: source)
                }
                continue
            }
            host.warmup.noteAutoWarmDecision(state, .warm)

            let previousQuotaFetchedAt = state.quotaSnapshot?.fetchedAt
            let succeeded = await host.warmup.triggerWarmup(
                tool: tool,
                mode: caughtUp ? "scheduled-catchup" : "scheduled"
            )
            if succeeded {
                rememberMorningWarmSuccess(for: tool, dayKey: todayKey)
                host.warmup.claimAutoWindowFromPostWarmQuota(for: tool, previousFetchedAt: previousQuotaFetchedAt)
                caughtUpSuccessfully = caughtUpSuccessfully || caughtUp
            }
        }

        if caughtUpSuccessfully, source != .timer {
            NotificationManager.shared.notifyMorningCatchUp(onBattery: !WakeScheduler.isOnACPower())
        }
        scheduleMorningTimer()
    }

    func logMorningSkip(tool: ProviderID, reason: String, source: ScheduledMorningSource) {
        DiagnosticLogger.append(
            "morning_warm_skipped tool=\(tool.rawValue) reason=\(reason) source=\(String(describing: source))"
        )
    }

    func handleSystemWake() {
        guard host.morningPrewarmEnabled else { return }
        guard let todaysMorning = todaysMorningDate(now: Date()), Date() >= todaysMorning else { return }
        Task { @MainActor in await runScheduledMorningWarmupIfNeeded(source: .wake) }
    }

    func nextMorningFireDate() -> Date? {
        var comps = DateComponents()
        comps.hour = host.settings.morningHour
        comps.minute = host.settings.morningMinute
        comps.second = 0
        let cal = Calendar.current
        guard var next = cal.nextDate(after: Date(), matching: comps, matchingPolicy: .nextTime) else { return nil }
        if host.settings.morningWeekdaysOnly {
            var guardCount = 0
            while cal.isDateInWeekend(next), guardCount < 8 {
                guard let bumped = cal.nextDate(after: next, matching: comps, matchingPolicy: .nextTime) else { break }
                next = bumped
                guardCount += 1
            }
        }
        return next
    }

    func todaysMorningDate(now: Date = Date()) -> Date? {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: now)
        comps.hour = host.settings.morningHour
        comps.minute = host.settings.morningMinute
        comps.second = 0
        return Calendar.current.date(from: comps)
    }

    func upcomingReservedMorningDate(now: Date = Date()) -> Date? {
        guard host.morningPrewarmEnabled, !host.globalPassive else { return nil }
        if host.settings.morningWeekdaysOnly, Calendar.current.isDateInWeekend(now) { return nil }
        guard let scheduledAt = todaysMorningDate(now: now), now < scheduledAt else { return nil }
        return scheduledAt
    }


    func lastMorningWarmDay(for tool: ProviderID, todayKey: String) -> String? {
        let perToolDay = host.settings.lastMorningWarmDay(tool.rawValue)
        let legacyDay = host.settings.lastMorningWarmDayLegacy
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

    func rememberMorningWarmSuccess(for tool: ProviderID, dayKey: String) {
        host.settings.setLastMorningWarmDay(dayKey, for: tool.rawValue)
    }

    private static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
}
