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

    static func make(_ input: Input, now: Date, calendar: Calendar = .current) -> AutoWarmExplanation {
        func time(_ date: Date) -> String { formatTime(date, now: now, calendar: calendar) }
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
            return make(.neutral, "Off", "This provider isn't watched or warmed.",
                        action: "Switch to Monitor or Auto-warm to track it.", subtle: true)
        case .monitor:
            return make(.neutral, "Monitor mode — warm-ups are never sent",
                        "QuotaWarmer only reads your quota here.",
                        action: "Switch to Auto-warm to open fresh windows automatically.", subtle: true)
        case .autoWarm:
            break
        }

        guard let decidedAt = input.decidedAt else {
            return make(.neutral, "Waiting for the first check",
                        "Auto-warm hasn't evaluated this provider yet.", next: input.nextCheckAt)
        }
        guard let skip = input.skip else {
            return make(.good, "Warmed at \(time(decidedAt))",
                        "A fresh window was detected and the warm-up was sent.",
                        next: input.windowResetAt)
        }

        switch skip {
        case .autoWarmOff:
            return make(.neutral, "Off", "Auto-warm isn't enabled for this provider.",
                        action: "Switch to Auto-warm to enable it.", subtle: true)
        case .paused:
            return make(.neutral, "Paused globally",
                        "All warm-ups are paused, so nothing is sent.",
                        action: "Resume in the menu to re-enable auto-warm.")
        case .warmupInProgress:
            return make(.neutral, "Warm-up running",
                        "A warm-up is being sent right now.", next: input.nextCheckAt)
        case .authUnavailable(let status):
            let what = status == .missing ? "No sign-in was found" : "The sign-in was rejected"
            return make(.attention, "Sign-in \(status.label)",
                        "\(what), so quota can't be checked or warmed.",
                        action: "Sign in with the provider's CLI, then press Refresh.")
        case .backoff(let until):
            return make(.attention, "Backing off after a failed warm-up until \(time(until))",
                        "The last warm-up failed, so retries are delayed to avoid hammering the provider.",
                        action: "Wait, or turn off the rate-limit guard in Settings to retry sooner.",
                        next: until)
        case .sourceUnhealthy(let health):
            return make(.attention, "Quota source \(health.label)",
                        "The latest quota check wasn't healthy, so a fresh window can't be confirmed.",
                        action: "Press Refresh; check sign-in if it persists.", next: input.nextCheckAt)
        case .noQuotaReading:
            return make(.neutral, "No 5h quota reading yet",
                        "The provider hasn't reported a 5-hour window with a reset time.",
                        next: input.nextCheckAt)
        case .snapshotNotFresh(let freshness):
            var lead = "Quota reading \(freshness.label)"
            if let fetched = input.snapshotFetchedAt, now > fetched {
                lead = "Snapshot is \(max(1, Int(now.timeIntervalSince(fetched) / 60))) min old"
            }
            return make(.neutral, "\(lead) — waiting for a fresh check",
                        "Auto-warm only acts on a reading from the last 5 minutes.",
                        action: "Press Refresh to check now.", next: input.nextCheckAt)
        case .windowInUse(let remaining):
            let left = Int((remaining * 100).rounded())
            return make(.neutral, "Window in use (\(left)% left)",
                        "A window is already running, so there's nothing to open.",
                        next: input.windowResetAt)
        case .windowNotJustOpened:
            return make(.neutral, "Window already running",
                        "The window opened more than 10 minutes ago, so it's too late to claim it.",
                        next: input.windowResetAt)
        case .reservedForMorning(let at):
            return make(.neutral, "Reserved for the \(time(at)) pre-warm",
                        "The morning pre-warm will open the next window at \(time(at)).",
                        action: "Change or disable it in Settings.", next: at)
        case .alreadyWarmedWindow:
            let reset = input.windowResetAt.map { " (resets \(time($0)))" } ?? ""
            return make(.neutral, "Already warmed this window\(reset)",
                        "This window was warmed already; it won't be warmed twice.",
                        next: input.windowResetAt)
        case .warmedWindowActive(let until):
            return make(.neutral, "Already warmed this window (resets \(time(until)))",
                        "The window we warmed is still open; the next warm-up waits for the reset.",
                        next: until)
        case .morning(let reason):
            return morning(reason, make: make, time: time, input: input)
        }
    }

    private static func morning(
        _ reason: ScheduledWarmupSkipReason,
        make: (Tone, String, String, String?, Date?, Bool) -> AutoWarmExplanation,
        time: (Date) -> String,
        input: Input
    ) -> AutoWarmExplanation {
        switch reason {
        case .alreadySucceeded:
            return make(.neutral, "Morning pre-warm done today",
                        "Today's scheduled warm-up already succeeded.", nil, nil, false)
        case .beforeScheduledTime:
            return make(.neutral, "Morning pre-warm not due yet",
                        "The scheduled warm-up runs at its set time.", nil, input.nextCheckAt, false)
        case .outsideCatchUpHorizon:
            return make(.neutral, "Morning pre-warm missed",
                        "The Mac was asleep too long past the scheduled time to catch up.",
                        "Keep the Mac awake or enable the wake schedule in Settings.", nil, false)
        case .activeWindowInProgress:
            return make(.neutral, "Morning pre-warm skipped — window already running",
                        "A window is already open, so there's nothing to claim.",
                        nil, input.windowResetAt, false)
        case .quotaSourceUnavailable:
            return make(.attention, "Morning pre-warm skipped — quota unavailable",
                        "A fresh, healthy quota reading was needed first and wasn't available.",
                        "Press Refresh; check sign-in if it persists.", input.nextCheckAt, false)
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
        let explanation = make(Input(mode: .autoWarm, skip: new, decidedAt: now), now: now, calendar: calendar)
        guard explanation.isUserRelevantSkip else { return nil }
        return ("Auto-warm skipped", explanation.status + ". " + explanation.detail)
    }

    // MARK: - Formatting

    /// "14:30" today, "Wed 14:30" on another day. 24-hour, calendar's zone.
    static func formatTime(_ date: Date, now: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let hm = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        if calendar.isDate(date, inSameDayAs: now) { return hm }
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let weekday = calendar.component(.weekday, from: date)
        return "\(names[(weekday - 1) % 7]) \(hm)"
    }

    /// Popover body, one block per line: detail, action, timing.
    func popoverLines(now: Date, calendar: Calendar = .current) -> [String] {
        var lines = [detail]
        if let action { lines.append(action) }
        if let next = nextEligibleAt, next > now {
            lines.append("Next eligible: \(Self.formatTime(next, now: now, calendar: calendar))")
        }
        if let decidedAt {
            lines.append("Last checked \(Self.formatTime(decidedAt, now: now, calendar: calendar))")
        }
        return lines
    }
}
