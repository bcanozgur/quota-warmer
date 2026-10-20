import Foundation

/// The three proactive quota warnings. Each fires at most once per quota window.
enum QuotaAlertKind: String, Codable, CaseIterable {
    case session    // 5h window crossed a used% threshold
    case weekly     // weekly window crossed a used% threshold
    case pace       // 5h window projected to run out before it resets
}

/// What was last alerted for one alert kind: the window it belonged to and the
/// highest threshold already announced in it. Persisted per account.
struct QuotaAlertMark: Codable, Equatable {
    var windowKey: String
    var resetAt: Date?
    /// Highest used% threshold announced in this window (pace uses 100).
    var level: Int

    static func defaultsKey(storageKey: String) -> String { "quotaAlertMarks.\(storageKey)" }

    static func load(storageKey: String, defaults: UserDefaults = .standard) -> [String: QuotaAlertMark] {
        guard let data = defaults.data(forKey: defaultsKey(storageKey: storageKey)),
              let marks = try? JSONDecoder().decode([String: QuotaAlertMark].self, from: data) else { return [:] }
        return marks
    }

    static func save(_ marks: [String: QuotaAlertMark], storageKey: String, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(marks) else { return }
        defaults.set(data, forKey: defaultsKey(storageKey: storageKey))
    }
}

/// Settings → Alerts. Thresholds are whole used percents.
struct QuotaAlertSettings: Equatable {
    var sessionEnabled = true
    var sessionThresholds = Self.defaultSessionThresholds
    var weeklyEnabled = true
    var weeklyThresholds = Self.defaultWeeklyThresholds
    var paceEnabled = true

    static let defaultSessionThresholds = [80, 95]
    static let defaultWeeklyThresholds = [75, 90]
    /// Choices offered by the threshold pickers.
    static let thresholdChoices = [50, 60, 70, 75, 80, 85, 90, 95]

    static let sessionEnabledKey = "alertSessionEnabled"
    static let sessionFirstKey = "alertSessionFirst"
    static let sessionSecondKey = "alertSessionSecond"
    static let weeklyEnabledKey = "alertWeeklyEnabled"
    static let weeklyFirstKey = "alertWeeklyFirst"
    static let weeklySecondKey = "alertWeeklySecond"
    static let paceEnabledKey = "alertPaceEnabled"

    /// Next pick for a click-to-cycle threshold control; wraps to the first.
    static func nextThreshold(after value: Int) -> Int {
        thresholdChoices.first { $0 > value } ?? thresholdChoices[0]
    }

    static func load(from defaults: UserDefaults = .standard) -> QuotaAlertSettings {
        func bool(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
        func int(_ key: String, _ fallback: Int) -> Int { defaults.object(forKey: key) as? Int ?? fallback }
        return QuotaAlertSettings(
            sessionEnabled: bool(sessionEnabledKey),
            sessionThresholds: [int(sessionFirstKey, defaultSessionThresholds[0]),
                                int(sessionSecondKey, defaultSessionThresholds[1])],
            weeklyEnabled: bool(weeklyEnabledKey),
            weeklyThresholds: [int(weeklyFirstKey, defaultWeeklyThresholds[0]),
                               int(weeklySecondKey, defaultWeeklyThresholds[1])],
            paceEnabled: bool(paceEnabledKey)
        )
    }
}

struct QuotaAlert: Equatable {
    let kind: QuotaAlertKind
    /// Used% the alert announces (the actual, displayed value).
    let usedPercent: Int
    let resetIn: TimeInterval
    /// Projected run-out, when the 5h window is behind pace.
    let runsOutIn: TimeInterval?

    func title(toolName: String) -> String {
        switch kind {
        case .session: return "\(toolName) — \(usedPercent)% of 5h quota used"
        case .weekly: return "\(toolName) — \(usedPercent)% of weekly quota used"
        case .pace: return "\(toolName) — On pace to run out"
        }
    }

    var body: String {
        let left = 100 - usedPercent
        let reset = quotaDurationText(Int(resetIn))
        switch kind {
        case .session, .weekly:
            var text = "\(left)% left, resets in \(reset)."
            if let runsOutIn {
                text += " At this pace it runs out in \(quotaDurationText(Int(runsOutIn))) — before reset."
            }
            return text
        case .pace:
            let runsOut = quotaDurationText(Int(runsOutIn ?? 0))
            return "Runs out in \(runsOut) — before the 5h reset in \(reset). \(usedPercent)% used."
        }
    }
}

/// Decides which proactive quota notifications are due for a fresh snapshot.
/// Pure: the caller persists `marks` and posts `alerts`.
///
/// Dedup is per window. A window is recognised by the snapshot's `rawWindowKey`
/// (5h) or weekly reset time, *or* by a reset within `sameWindowTolerance` of the
/// marked one — Codex derives its reset from `reset_after_seconds`, so the key
/// drifts a few seconds every poll and exact matching alone would re-alert.
enum QuotaAlertPolicy {
    struct Evaluation: Equatable {
        var alerts: [QuotaAlert]
        var marks: [String: QuotaAlertMark]
    }

    /// Fraction of a window's length within which two resets are the same window.
    static let sameWindowTolerance = 0.05
    /// Burn-rate extrapolation is noise in a window's first minutes; a pace alert
    /// needs this much elapsed time and usage before it may fire.
    static let paceMinElapsed: TimeInterval = 15 * 60
    static let paceMinUsedPercent = 20

    static func evaluate(
        snapshot: QuotaSnapshot,
        settings: QuotaAlertSettings,
        marks: [String: QuotaAlertMark],
        fiveHourDuration: TimeInterval,
        weeklyDuration: TimeInterval,
        now: Date = Date()
    ) -> Evaluation {
        var result = Evaluation(alerts: [], marks: marks)
        guard snapshot.freshness(now: now) == .fresh else { return result }

        if let window = sessionWindow(snapshot, fiveHourDuration: fiveHourDuration, now: now) {
            let used = QuotaDisplay.usedPercent(remainingFraction: window.metric.remainingFraction)
            let resetIn = window.resetAt.timeIntervalSince(now)
            let paceDue = settings.paceEnabled
                && !isMarked(marks[QuotaAlertKind.pace.rawValue], window: window, level: 100, duration: fiveHourDuration)
                ? paceRunsOut(window.metric, resetAt: window.resetAt, duration: fiveHourDuration, now: now)
                : nil

            var sessionFired = false
            if settings.sessionEnabled,
               let threshold = crossedThreshold(used: used, thresholds: settings.sessionThresholds),
               !isMarked(marks[QuotaAlertKind.session.rawValue], window: window, level: threshold, duration: fiveHourDuration) {
                // A due pace warning rides along instead of a second notification.
                result.alerts.append(QuotaAlert(kind: .session, usedPercent: used, resetIn: resetIn, runsOutIn: paceDue))
                result.marks[QuotaAlertKind.session.rawValue] = window.mark(level: threshold)
                sessionFired = true
            }
            if let paceDue {
                if !sessionFired {
                    result.alerts.append(QuotaAlert(kind: .pace, usedPercent: used, resetIn: resetIn, runsOutIn: paceDue))
                }
                result.marks[QuotaAlertKind.pace.rawValue] = window.mark(level: 100)
            }
        }

        if settings.weeklyEnabled,
           let metric = snapshot.weekly, !metric.isIdle,
           let resetAt = metric.resetAt, resetAt > now {
            let window = Window(key: "weekly|\(ISO8601DateFormatter().string(from: resetAt))", resetAt: resetAt, metric: metric)
            let used = QuotaDisplay.usedPercent(remainingFraction: metric.remainingFraction)
            if let threshold = crossedThreshold(used: used, thresholds: settings.weeklyThresholds),
               !isMarked(marks[QuotaAlertKind.weekly.rawValue], window: window, level: threshold, duration: weeklyDuration) {
                result.alerts.append(QuotaAlert(kind: .weekly, usedPercent: used,
                                                resetIn: resetAt.timeIntervalSince(now), runsOutIn: nil))
                result.marks[QuotaAlertKind.weekly.rawValue] = window.mark(level: threshold)
            }
        }
        return result
    }

    /// Highest configured threshold the usage has reached, or nil. Jumping past
    /// several at once announces only the highest.
    static func crossedThreshold(used: Int, thresholds: [Int]) -> Int? {
        thresholds.filter { (1...100).contains($0) && used >= $0 }.max()
    }

    /// Whether `mark` already covers `window` at `level` or above.
    static func isMarked(_ mark: QuotaAlertMark?, window: Window, level: Int, duration: TimeInterval) -> Bool {
        guard let mark, mark.level >= level else { return false }
        if mark.windowKey == window.key { return true }
        guard let markedReset = mark.resetAt else { return false }
        return abs(markedReset.timeIntervalSince(window.resetAt)) <= duration * sameWindowTolerance
    }

    struct Window {
        let key: String
        let resetAt: Date
        let metric: QuotaMetric

        func mark(level: Int) -> QuotaAlertMark {
            QuotaAlertMark(windowKey: key, resetAt: resetAt, level: level)
        }
    }

    /// The live, opened, settled 5h window — the only one worth warning about.
    /// Idle windows are full by definition, and a just-rolled-over reading is a
    /// transient near-empty artifact the UI already refuses to alarm on.
    private static func sessionWindow(_ snapshot: QuotaSnapshot, fiveHourDuration: TimeInterval, now: Date) -> Window? {
        guard let metric = snapshot.fiveHour, !metric.isIdle,
              let resetAt = metric.resetAt, resetAt > now,
              !snapshot.isUnsettledRolloverReading(windowDuration: fiveHourDuration, now: now) else { return nil }
        return Window(key: snapshot.rawWindowKey, resetAt: resetAt, metric: metric)
    }

    /// Seconds until the 5h quota runs out at the current burn rate, when that
    /// is before the reset — the same projection the bars show as "Runs out in".
    private static func paceRunsOut(_ metric: QuotaMetric, resetAt: Date, duration: TimeInterval, now: Date) -> TimeInterval? {
        let quotaLeft = metric.remainingFraction
        guard quotaLeft > 0,
              QuotaDisplay.usedPercent(remainingFraction: quotaLeft) >= paceMinUsedPercent,
              duration - resetAt.timeIntervalSince(now) >= paceMinElapsed else { return nil }
        let pace = QuotaPace.compute(quotaLeft: quotaLeft, resetAt: resetAt, windowDuration: duration,
                                     now: now, fallbackResetText: "")
        return pace.runsOutIn
    }
}
