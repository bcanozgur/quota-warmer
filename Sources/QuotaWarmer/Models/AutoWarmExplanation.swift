import Foundation

/// Plain-language answer to "why didn't it warm?" for one tool. Pure and
/// clock-injected: `AppState` gathers the inputs, the views render the result,
/// and `scripts/quota-display-regression.swift` pins every reason's text.
struct AutoWarmExplanation: Equatable {
    enum Tone: Equatable {
        /// Nothing to act on (waiting, off, healthy skip).
        case neutral
        /// Warm-up will fire / just did.
        case good
        /// Something the user may want to fix (sign-in, backoff, source).
        case attention
    }

    struct Input {
        var mode: ToolMode
        /// Last evaluation's skip reason; nil when it warmed or none ran yet.
        var skip: AutoWarmSkipReason?
        /// When the last evaluation ran; nil before the first one.
        var decidedAt: Date?
        /// When the next quota check is scheduled, if known.
        var nextCheckAt: Date?
        /// When the current 5h window resets, if known.
        var windowResetAt: Date?
        /// When the quota snapshot was fetched, for "Snapshot is N min old".
        var snapshotFetchedAt: Date?
    }

    var tone: Tone
    /// One short line for the card.
    var status: String
    /// One plain sentence for the popover.
    var detail: String
    /// What the user can do, when there is something.
    var action: String?
    /// When the tool is expected to be eligible/checked again.
    var nextEligibleAt: Date?
    var decidedAt: Date?

    /// Hidden for Off; Monitor gets a subtle line, Auto-warm the full status.
    var isSubtle: Bool

    // MARK: - Building

    /// `locale` picks the language of the returned text. UI callers use the
    /// current locale; the persisted event-log line passes English so the log
    /// stays stable whatever language the app runs in.
    static func make(
        _ input: Input, now: Date, calendar: Calendar = .current, locale: Locale = .current
    ) -> AutoWarmExplanation {
        func time(_ date: Date) -> String { formatTime(date, now: now, calendar: calendar, locale: locale) }
        func make(
            _ tone: Tone, _ status: String, _ detail: String, action: String? = nil,
            next: Date? = nil, subtle: Bool = false
        ) -> AutoWarmExplanation {
            AutoWarmExplanation(
                tone: tone, status: status, detail: detail, action: action,
                nextEligibleAt: next, decidedAt: input.decidedAt, isSubtle: subtle
            )
        }

        switch input.mode {
        case .off:
            return make(.neutral, String(localized: "Off", locale: locale),
                        String(localized: "This provider isn't watched or warmed.", locale: locale),
                        action: String(localized: "Switch to Monitor or Auto-warm to track it.", locale: locale),
                        subtle: true)
        case .monitor:
            return make(.neutral, String(localized: "Monitor mode — warm-ups are never sent", locale: locale),
                        String(localized: "QuotaWarmer only reads your quota here.", locale: locale),
                        action: String(localized: "Switch to Auto-warm to open fresh windows automatically.", locale: locale),
                        subtle: true)
        case .autoWarm:
            break
        }

        guard let decidedAt = input.decidedAt else {
            return make(.neutral, String(localized: "Waiting for the first check", locale: locale),
                        String(localized: "Auto-warm hasn't evaluated this provider yet.", locale: locale),
                        next: input.nextCheckAt)
        }
        guard let skip = input.skip else {
            return make(.good, String(localized: "Warmed at \(time(decidedAt))", locale: locale),
                        String(localized: "A fresh window was detected and the warm-up was sent.", locale: locale),
                        next: input.windowResetAt)
        }

        switch skip {
        case .autoWarmOff:
            return make(.neutral, String(localized: "Off", locale: locale),
                        String(localized: "Auto-warm isn't enabled for this provider.", locale: locale),
                        action: String(localized: "Switch to Auto-warm to enable it.", locale: locale), subtle: true)
        case .paused:
            return make(.neutral, String(localized: "Paused globally", locale: locale),
                        String(localized: "All warm-ups are paused, so nothing is sent.", locale: locale),
                        action: String(localized: "Resume in the menu to re-enable auto-warm.", locale: locale))
        case .warmupInProgress:
            return make(.neutral, String(localized: "Warm-up running", locale: locale),
                        String(localized: "A warm-up is being sent right now.", locale: locale), next: input.nextCheckAt)
        case .authUnavailable(let status):
            let what = status == .missing
                ? String(localized: "No sign-in was found", locale: locale)
                : String(localized: "The sign-in was rejected", locale: locale)
            return make(.attention, String(localized: "Sign-in \(status.displayLabel(locale: locale))", locale: locale),
                        String(localized: "\(what), so quota can't be checked or warmed.", locale: locale),
                        action: String(localized: "Sign in with the provider's CLI, then press Refresh.", locale: locale))
        case .backoff(let until):
            return make(.attention,
                        String(localized: "Backing off after a failed warm-up until \(time(until))", locale: locale),
                        String(localized: "The last warm-up failed, so retries are delayed to avoid hammering the provider.", locale: locale),
                        action: String(localized: "Wait, or turn off the rate-limit guard in Settings to retry sooner.", locale: locale),
                        next: until)
        case .sourceUnhealthy(let health):
            return make(.attention, String(localized: "Quota source \(health.displayLabel(locale: locale))", locale: locale),
                        String(localized: "The latest quota check wasn't healthy, so a fresh window can't be confirmed.", locale: locale),
                        action: String(localized: "Press Refresh; check sign-in if it persists.", locale: locale),
                        next: input.nextCheckAt)
        case .noQuotaReading:
            return make(.neutral, String(localized: "No 5h quota reading yet", locale: locale),
                        String(localized: "The provider hasn't reported a 5-hour window with a reset time.", locale: locale),
                        next: input.nextCheckAt)
        case .snapshotNotFresh(let freshness):
            var lead = String(localized: "Quota reading \(freshness.displayLabel(locale: locale))", locale: locale)
            if let fetched = input.snapshotFetchedAt, now > fetched {
                let minutes = max(1, Int(now.timeIntervalSince(fetched) / 60))
                lead = String(localized: "Snapshot is \(minutes) min old", locale: locale)
            }
            return make(.neutral, String(localized: "\(lead) — waiting for a fresh check", locale: locale),
                        String(localized: "Auto-warm only acts on a reading from the last 5 minutes.", locale: locale),
                        action: String(localized: "Press Refresh to check now.", locale: locale), next: input.nextCheckAt)
        case .windowInUse(let remaining):
            let left = Int((remaining * 100).rounded())
            return make(.neutral, String(localized: "Window in use (\(left)% left)", locale: locale),
                        String(localized: "A window is already running, so there's nothing to open.", locale: locale),
                        next: input.windowResetAt)
        case .windowNotJustOpened:
            return make(.neutral, String(localized: "Window already running", locale: locale),
                        String(localized: "The window opened more than 10 minutes ago, so it's too late to claim it.", locale: locale),
                        next: input.windowResetAt)
        case .reservedForMorning(let at):
            return make(.neutral, String(localized: "Reserved for the \(time(at)) pre-warm", locale: locale),
                        String(localized: "The morning pre-warm will open the next window at \(time(at)).", locale: locale),
                        action: String(localized: "Change or disable it in Settings.", locale: locale), next: at)
        case .alreadyWarmedWindow:
            let reset = input.windowResetAt.map { date in
                String(localized: " (resets \(time(date)))", locale: locale)
            } ?? ""
            return make(.neutral, String(localized: "Already warmed this window\(reset)", locale: locale),
                        String(localized: "This window was warmed already; it won't be warmed twice.", locale: locale),
                        next: input.windowResetAt)
        case .warmedWindowActive(let until):
            return make(.neutral, String(localized: "Already warmed this window (resets \(time(until)))", locale: locale),
                        String(localized: "The window we warmed is still open; the next warm-up waits for the reset.", locale: locale),
                        next: until)
        case .morning(let reason):
            return morning(reason, make: make, time: time, input: input, locale: locale)
        }
    }

    private static func morning(
        _ reason: ScheduledWarmupSkipReason,
        make: (Tone, String, String, String?, Date?, Bool) -> AutoWarmExplanation,
        time: (Date) -> String,
        input: Input,
        locale: Locale
    ) -> AutoWarmExplanation {
        switch reason {
        case .alreadySucceeded:
            return make(.neutral, String(localized: "Morning pre-warm done today", locale: locale),
                        String(localized: "Today's scheduled warm-up already succeeded.", locale: locale), nil, nil, false)
        case .beforeScheduledTime:
            return make(.neutral, String(localized: "Morning pre-warm not due yet", locale: locale),
                        String(localized: "The scheduled warm-up runs at its set time.", locale: locale), nil, input.nextCheckAt, false)
        case .outsideCatchUpHorizon:
            return make(.neutral, String(localized: "Morning pre-warm missed", locale: locale),
                        String(localized: "The Mac was asleep too long past the scheduled time to catch up.", locale: locale),
                        String(localized: "Keep the Mac awake or enable the wake schedule in Settings.", locale: locale), nil, false)
        case .activeWindowInProgress:
            return make(.neutral, String(localized: "Morning pre-warm skipped — window already running", locale: locale),
                        String(localized: "A window is already open, so there's nothing to claim.", locale: locale),
                        nil, input.windowResetAt, false)
        case .quotaSourceUnavailable:
            return make(.attention, String(localized: "Morning pre-warm skipped — quota unavailable", locale: locale),
                        String(localized: "A fresh, healthy quota reading was needed first and wasn't available.", locale: locale),
                        String(localized: "Press Refresh; check sign-in if it persists.", locale: locale), input.nextCheckAt, false)
        }
    }

    // MARK: - Dedup and history

    /// Reasons worth a history entry when they first appear. Routine waiting
    /// states (window in use, already warmed, not fresh) stay out of history.
    var isUserRelevantSkip: Bool { tone == .attention }

    /// Stable identity of a skip ignoring drifting associated values (a backoff
    /// deadline, a remaining fraction), so the same reason isn't re-recorded.
    static func dedupKey(_ reason: AutoWarmSkipReason?) -> String {
        guard let reason else { return "warm" }
        switch reason {
        case .autoWarmOff: return "autoWarmOff"
        case .paused: return "paused"
        case .warmupInProgress: return "warmupInProgress"
        case .authUnavailable(let s): return "auth.\(s.rawValue)"
        case .backoff: return "backoff"
        case .sourceUnhealthy(let h): return "source.\(h.rawValue)"
        case .noQuotaReading: return "noQuotaReading"
        case .snapshotNotFresh(let f): return "fresh.\(f.rawValue)"
        case .windowInUse: return "windowInUse"
        case .windowNotJustOpened: return "windowNotJustOpened"
        case .reservedForMorning: return "reservedForMorning"
        case .alreadyWarmedWindow: return "alreadyWarmedWindow"
        case .warmedWindowActive: return "warmedWindowActive"
        case .morning(let r): return "morning.\(r.rawValue)"
        }
    }

    /// The history line to record when the skip reason changed to `new`, or
    /// nil when nothing should be recorded (unchanged, or not user-relevant).
    static func historyEntry(
        previous: AutoWarmSkipReason?, new: AutoWarmSkipReason?, now: Date, calendar: Calendar = .current
    ) -> (title: String, detail: String)? {
        guard let new, dedupKey(previous) != dedupKey(new) else { return nil }
        // English on purpose: this line is persisted to the event log.
        let englishLocale = Locale(identifier: "en")
        let explanation = make(
            Input(mode: .autoWarm, skip: new, decidedAt: now), now: now, calendar: calendar, locale: englishLocale)
        guard explanation.isUserRelevantSkip else { return nil }
        return ("Auto-warm skipped", explanation.status + ". " + explanation.detail)
    }

    // MARK: - Formatting

    /// "14:30" today, "Wed 14:30" on another day. 24-hour, calendar's zone.
    static func formatTime(_ date: Date, now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let hm = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        if calendar.isDate(date, inSameDayAs: now) { return hm }
        let names = [
            String(localized: "Sun", locale: locale), String(localized: "Mon", locale: locale),
            String(localized: "Tue", locale: locale), String(localized: "Wed", locale: locale),
            String(localized: "Thu", locale: locale), String(localized: "Fri", locale: locale),
            String(localized: "Sat", locale: locale),
        ]
        let weekday = calendar.component(.weekday, from: date)
        return "\(names[(weekday - 1) % 7]) \(hm)"
    }

    /// Popover body, one block per line: detail, action, timing.
    func popoverLines(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> [String] {
        var lines = [detail]
        if let action { lines.append(action) }
        if let next = nextEligibleAt, next > now {
            let time = Self.formatTime(next, now: now, calendar: calendar, locale: locale)
            lines.append(String(localized: "Next eligible: \(time)", locale: locale))
        }
        if let decidedAt {
            let time = Self.formatTime(decidedAt, now: now, calendar: calendar, locale: locale)
            lines.append(String(localized: "Last checked \(time)", locale: locale))
        }
        return lines
    }
}
