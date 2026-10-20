import Foundation

/// Regression suite for quota *presentation*: remaining-vs-used display mode,
/// Claude-style bar colors, bar/knob geometry and the menu-bar text. Compiled
/// standalone like quota-extractor-regression.swift (see .github/workflows/ci.yml)
/// and runs every percent through the real Claude/Codex parsers, so what the
/// user sees is checked against what the providers actually report.
@main
struct QuotaDisplayRegression {
    nonisolated(unsafe) static var failures: [String] = []
    nonisolated(unsafe) static var checks = 0

    static func main() async {
        DebugLevel.current = .off
        testPercents()
        testRealProviderPercents()
        testUsageLevels()
        testBarGeometry()
        testRowText()
        testMenuBarText()
        testModePersistence()
        testAppearanceMode()
        testTimeInput()
        testColorfulSetting()
        testQuotaAlerts()

        if failures.isEmpty {
            print("Quota display regressions passed (\(checks) checks)")
        } else {
            for failure in failures { print("FAIL: \(failure)") }
            print("\(failures.count) of \(checks) quota display checks failed")
            exit(1)
        }
    }

    // MARK: - Percent math

    static func testPercents() {
        expect(QuotaDisplay.remainingPercent(remainingFraction: 1), 100, "full window is 100% left")
        expect(QuotaDisplay.usedPercent(remainingFraction: 1), 0, "full window is 0% used")
        expect(QuotaDisplay.remainingPercent(remainingFraction: 0), 0, "empty window is 0% left")
        expect(QuotaDisplay.usedPercent(remainingFraction: 0), 100, "empty window is 100% used")
        // Out-of-range fractions clamp instead of producing 120% / -20%.
        expect(QuotaDisplay.usedPercent(remainingFraction: 1.2), 0, "over-full clamps to 0% used")
        expect(QuotaDisplay.usedPercent(remainingFraction: -0.2), 100, "negative clamps to 100% used")
        // Truncation (never show a window as full before it is) survives.
        expect(QuotaDisplay.remainingPercent(remainingFraction: 0.999), 99, "0.999 left truncates to 99%")
        expect(QuotaDisplay.usedPercent(remainingFraction: 0.999), 1, "0.999 left is 1% used")
        // Float error: 0.29 * 100 == 28.999…; must still read 29.
        expect(QuotaDisplay.remainingPercent(remainingFraction: 0.29), 29, "0.29 left is 29%, not 28%")
        expect(QuotaDisplay.remainingPercent(remainingFraction: 0.57), 57, "0.57 left is 57%, not 56%")
        for whole in 0...100 {
            let fraction = Double(whole) / 100
            expect(QuotaDisplay.remainingPercent(remainingFraction: fraction), whole, "\(whole)/100 left")
            expect(QuotaDisplay.remainingPercent(remainingFraction: fraction)
                   + QuotaDisplay.usedPercent(remainingFraction: fraction), 100, "left + used == 100 at \(whole)%")
            expect(QuotaDisplay.percent(remainingFraction: fraction, mode: .remaining),
                   QuotaDisplay.remainingPercent(remainingFraction: fraction), "remaining mode percent at \(whole)%")
            expect(QuotaDisplay.percent(remainingFraction: fraction, mode: .used),
                   QuotaDisplay.usedPercent(remainingFraction: fraction), "used mode percent at \(whole)%")
        }
    }

    /// Every whole utilization value, through the same parsers the app uses.
    static func testRealProviderPercents() {
        let provider = QuotaProvider()
        let reset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3 * 3600))
        let weeklyReset = Date().addingTimeInterval(4 * 86_400)
        for used in 0...100 {
            let claude = provider.claudeSnapshot(
                payload: [
                    "five_hour": ["utilization": used, "resets_at": reset],
                    "seven_day": ["utilization": used, "resets_at": reset]
                ],
                source: "Claude OAuth usage",
                corroboratingSource: nil,
                message: nil
            )
            for (label, metric) in [("5h", claude.fiveHour), ("weekly", claude.weekly)] {
                guard let fraction = metric?.remainingFraction else {
                    fail("Claude \(label) metric missing at \(used)% used"); continue
                }
                expect(QuotaDisplay.usedPercent(remainingFraction: fraction), used, "Claude \(label) \(used)% used shows as used")
                expect(QuotaDisplay.remainingPercent(remainingFraction: fraction), 100 - used, "Claude \(label) \(used)% used shows as left")
            }

            let codex = provider.codexSnapshot(
                payload: [
                    "rate_limit": [
                        "primary_window": [
                            "used_percent": used,
                            "limit_window_seconds": 18000,
                            "reset_after_seconds": 10_000
                        ],
                        "secondary_window": [
                            "used_percent": used,
                            "limit_window_seconds": 604800,
                            "reset_at": Int(weeklyReset.timeIntervalSince1970)
                        ]
                    ]
                ],
                source: "test",
                message: nil
            )
            for (label, metric) in [("5h", codex.fiveHour), ("weekly", codex.weekly)] {
                guard let fraction = metric?.remainingFraction else {
                    fail("Codex \(label) metric missing at \(used)% used"); continue
                }
                expect(QuotaDisplay.usedPercent(remainingFraction: fraction), used, "Codex \(label) \(used)% used shows as used")
                expect(QuotaDisplay.remainingPercent(remainingFraction: fraction), 100 - used, "Codex \(label) \(used)% used shows as left")
            }
        }
    }

    // MARK: - Colors

    static func testUsageLevels() {
        for used in 0...100 {
            let level = QuotaUsageLevel(remainingFraction: Double(100 - used) / 100)
            let expected: QuotaUsageLevel = used >= 80 ? .critical : used >= 50 ? .warning : .normal
            expect(level, expected, "\(used)% used color band")
        }
        // The claude.ai screenshot: 29% used is blue, 95% used is red.
        expect(QuotaUsageLevel(remainingFraction: 0.71), .normal, "29% used is blue")
        expect(QuotaUsageLevel(remainingFraction: 0.05), .critical, "95% used is red")
        // Boundaries agree with the displayed number, not raw float error.
        expect(QuotaUsageLevel(remainingFraction: 0.50), .warning, "exactly 50% used is orange")
        expect(QuotaUsageLevel(remainingFraction: 0.511), .normal, "51.1% left (shown 49% used) stays blue")
        expect(QuotaUsageLevel(remainingFraction: 0.501), .warning, "50.1% left (shown 50% used) is orange, matching its label")
        expect(QuotaUsageLevel(remainingFraction: 0.219), .warning, "21.9% left (shown 79% used) stays orange")
        expect(QuotaUsageLevel(remainingFraction: 0.20), .critical, "exactly 80% used is red")
        expect(QuotaUsageLevel(remainingFraction: 0.201), .critical, "20.1% left (shown 80% used) is red, matching its label")
        expect(QuotaUsageLevel(remainingFraction: 1.5), .normal, "over-full clamps to blue")
        expect(QuotaUsageLevel(remainingFraction: -1), .critical, "negative clamps to red")
    }

    // MARK: - Bar geometry

    static func testBarGeometry() {
        close(QuotaDisplay.barFraction(remainingFraction: 0.8, hasMetric: true, mode: .remaining), 0.8, "remaining bar drains")
        close(QuotaDisplay.barFraction(remainingFraction: 0.8, hasMetric: true, mode: .used), 0.2, "used bar fills")
        close(QuotaDisplay.barFraction(remainingFraction: 1, hasMetric: true, mode: .used), 0, "fresh window: used bar starts at 0")
        close(QuotaDisplay.barFraction(remainingFraction: 1, hasMetric: true, mode: .remaining), 1, "fresh window: remaining bar starts full")
        // No data must never paint a full "used" bar.
        close(QuotaDisplay.barFraction(remainingFraction: 0, hasMetric: false, mode: .used), 0, "no metric: used bar empty")
        close(QuotaDisplay.barFraction(remainingFraction: 0, hasMetric: false, mode: .remaining), 0, "no metric: remaining bar empty")
        close(QuotaDisplay.barFraction(remainingFraction: 2, hasMetric: true, mode: .used), 0, "bar clamps high")
        close(QuotaDisplay.barFraction(remainingFraction: -1, hasMetric: true, mode: .used), 1, "bar clamps low")

        expectNil(QuotaDisplay.thumbFraction(timeLeftFraction: nil, mode: .used), "no reset: no knob")
        close(QuotaDisplay.thumbFraction(timeLeftFraction: 0.7, mode: .remaining), 0.7, "remaining knob = time left")
        close(QuotaDisplay.thumbFraction(timeLeftFraction: 0.7, mode: .used), 0.3, "used knob = time elapsed")

        // Behind pace must look the same in both modes: the fill passes the knob
        // on the "bad" side. 60% time left, 40% quota left → behind.
        let remaining = 0.4, timeLeft = 0.6
        let remBar = QuotaDisplay.barFraction(remainingFraction: remaining, hasMetric: true, mode: .remaining)
        let remKnob = QuotaDisplay.thumbFraction(timeLeftFraction: timeLeft, mode: .remaining)!
        let usedBar = QuotaDisplay.barFraction(remainingFraction: remaining, hasMetric: true, mode: .used)
        let usedKnob = QuotaDisplay.thumbFraction(timeLeftFraction: timeLeft, mode: .used)!
        check(remBar < remKnob, "remaining mode: behind pace = fill short of knob")
        check(usedBar > usedKnob, "used mode: behind pace = fill past knob")
        close(remKnob - remBar, usedBar - usedKnob, "same pace gap in both modes")
    }

    // MARK: - Text

    static func testRowText() {
        expect(QuotaDisplay.quotaText(remainingFraction: 0.71, isLive: true, mode: .remaining), "71% left", "live left text")
        expect(QuotaDisplay.quotaText(remainingFraction: 0.71, isLive: true, mode: .used), "29% used", "live used text (claude.ai style)")
        expect(QuotaDisplay.quotaText(remainingFraction: 0.05, isLive: true, mode: .used), "95% used", "95% used text")
        expect(QuotaDisplay.quotaText(remainingFraction: 0.71, isLive: false, mode: .remaining), "71% last known", "stale left text")
        expect(QuotaDisplay.quotaText(remainingFraction: 0.71, isLive: false, mode: .used), "29% last known", "stale used text")
        expect(QuotaDisplay.quotaText(remainingFraction: nil, isLive: true, mode: .remaining), "-- left", "no metric left text")
        expect(QuotaDisplay.quotaText(remainingFraction: nil, isLive: true, mode: .used), "-- used", "no metric used text")
    }

    static func testMenuBarText() {
        typealias Input = QuotaDisplay.MenuBarInput
        let r: TimeInterval = 3 * 3600 + 5 * 60 + 30
        for mode in QuotaDisplayMode.allCases {
            expect(QuotaDisplay.menuBarText(Input(isWarming: true, timeUntilReset: r, remainingFraction: 0.5), mode: mode),
                   "warming", "\(mode): warming wins")
            expect(QuotaDisplay.menuBarText(Input(sessionSettling: true, timeUntilReset: r, remainingFraction: 0), mode: mode),
                   "3h05m", "\(mode): settling shows countdown only")
            expect(QuotaDisplay.menuBarText(Input(), mode: mode), "", "\(mode): nothing known shows nothing")
        }

        let live = Input(timeUntilReset: r, remainingFraction: 0.71)
        expect(QuotaDisplay.menuBarText(live, mode: .remaining), "3h05m - 71%", "live left")
        expect(QuotaDisplay.menuBarText(live, mode: .used), "3h05m - 29%", "live used")

        let idle = Input(timeUntilReset: 4 * 3600, isIdleFiveHourWindow: true, remainingFraction: 1)
        expect(QuotaDisplay.menuBarText(idle, mode: .remaining), "100%", "idle window left, no fake countdown")
        expect(QuotaDisplay.menuBarText(idle, mode: .used), "0%", "idle window used, no fake countdown")
        let idleNoMetric = Input(isIdleFiveHourWindow: true)
        expect(QuotaDisplay.menuBarText(idleNoMetric, mode: .remaining), "100%", "idle without fraction treated as full")
        expect(QuotaDisplay.menuBarText(idleNoMetric, mode: .used), "0%", "idle without fraction is 0% used")

        let rolled = Input(primaryWindowRolledOver: true, remainingFraction: 0.02)
        expect(QuotaDisplay.menuBarText(rolled, mode: .remaining), "~100%", "rolled-over window restored (left)")
        expect(QuotaDisplay.menuBarText(rolled, mode: .used), "~0%", "rolled-over window restored (used)")

        let depleted = Input(remainingFraction: 0.12)
        expect(QuotaDisplay.menuBarText(depleted, mode: .remaining), "12%", "no countdown: left percent only")
        expect(QuotaDisplay.menuBarText(depleted, mode: .used), "88%", "no countdown: used percent only")

        let noMetricWithReset = Input(timeUntilReset: 42 * 60)
        expect(QuotaDisplay.menuBarText(noMetricWithReset, mode: .remaining), "42m - 0%", "countdown without metric keeps old left behavior")

        expect(QuotaDisplay.compactTime(59), "0m", "under a minute")
        expect(QuotaDisplay.compactTime(42 * 60), "42m", "minutes")
        expect(QuotaDisplay.compactTime(2 * 86_400 + 4 * 3600), "2d4h", "days")
        expect(QuotaDisplay.compactTime(-5), "0m", "negative clamps")
    }

    // MARK: - Persistence

    static func testModePersistence() {
        let suite = "QuotaDisplayRegression.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { fail("could not create defaults suite"); return }
        defer { defaults.removePersistentDomain(forName: suite) }

        for tool in ToolID.allCases {
            expect(QuotaDisplayMode.stored(for: tool, defaults: defaults), .remaining, "\(tool) defaults to remaining")
        }
        defaults.set(QuotaDisplayMode.used.rawValue, forKey: QuotaDisplayMode.defaultsKey(for: .claude))
        expect(QuotaDisplayMode.stored(for: .claude, defaults: defaults), .used, "Claude used mode persists")
        expect(QuotaDisplayMode.stored(for: .codex, defaults: defaults), .remaining, "Codex mode is independent of Claude")
        defaults.set("garbage", forKey: QuotaDisplayMode.defaultsKey(for: .codex))
        expect(QuotaDisplayMode.stored(for: .codex, defaults: defaults), .remaining, "unknown stored value falls back to remaining")
        check(QuotaDisplayMode.defaultsKey(for: .claude) != QuotaDisplayMode.defaultsKey(for: .codex), "per-tool keys differ")
        expect(QuotaDisplayMode.remaining.toggled, .used, "toggle remaining → used")
        expect(QuotaDisplayMode.used.toggled, .remaining, "toggle used → remaining")
    }

    // MARK: - Theme

    static func testAppearanceMode() {
        expect(AppearanceMode.system.next, .light, "theme cycle system → light")
        expect(AppearanceMode.light.next, .dark, "theme cycle light → dark")
        expect(AppearanceMode.dark.next, .system, "theme cycle dark → system")
        var mode = AppearanceMode.system
        var seen: [AppearanceMode] = []
        for _ in 0..<3 { seen.append(mode); mode = mode.next }
        expect(mode, .system, "three clicks return to system")
        expect(Set(seen), Set(AppearanceMode.allCases), "cycle visits every theme")
        expect(Set(AppearanceMode.allCases.map(\.symbolName)).count, 3, "each theme has its own icon")
        expect(AppearanceMode.system.symbolName, "circle.lefthalf.filled", "system icon")
        expect(AppearanceMode.light.symbolName, "sun.max", "light icon")
        expect(AppearanceMode.dark.symbolName, "moon", "dark icon")

        let suite = "QuotaDisplayRegression.theme.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { fail("could not create defaults suite"); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        expect(AppearanceMode.stored(defaults: defaults), .system, "theme defaults to system")
        for theme in AppearanceMode.allCases {
            defaults.set(theme.rawValue, forKey: AppearanceMode.defaultsKey)
            expect(AppearanceMode.stored(defaults: defaults), theme, "\(theme) theme persists")
        }
        defaults.set("sepia", forKey: AppearanceMode.defaultsKey)
        expect(AppearanceMode.stored(defaults: defaults), .system, "unknown theme falls back to system")
    }

    // MARK: - Colorful bars setting

    static func testColorfulSetting() {
        expect(QuotaDisplay.colorfulBarsKey, "colorfulQuotaBars", "setting key is stable (AppStorage in two views + Settings)")
        // Off: every row is the plain single-color style, whatever the usage.
        for used in [0, 29, 50, 79, 80, 95, 100] {
            let fraction = Double(100 - used) / 100
            expect(QuotaDisplay.colorLevel(remainingFraction: fraction, hasMetric: true, settling: false, colorful: false),
                   nil, "colorful off: \(used)% used is plain")
            expect(QuotaDisplay.colorLevel(remainingFraction: fraction, hasMetric: true, settling: false, colorful: true),
                   QuotaUsageLevel(remainingFraction: fraction), "colorful on: \(used)% used follows the band")
        }
        expect(QuotaDisplay.colorLevel(remainingFraction: 0, hasMetric: false, settling: false, colorful: false), nil, "off + no data is plain")
        expect(QuotaDisplay.colorLevel(remainingFraction: 0, hasMetric: false, settling: false, colorful: true), .normal, "on + no data stays calm blue, not red")
        expect(QuotaDisplay.colorLevel(remainingFraction: 0.02, hasMetric: true, settling: true, colorful: true), .normal, "on + settling stays calm blue")
        expect(QuotaDisplay.colorLevel(remainingFraction: 0.02, hasMetric: true, settling: false, colorful: true), .critical, "on + 98% used is red")
    }

    // MARK: - Wake-time field

    static func testTimeInput() {
        func parsed(_ raw: String) -> String? {
            TimeInput.parse(raw).map { TimeInput.text(hour: $0.hour, minute: $0.minute) }
        }
        let valid: [(String, String)] = [
            ("06:00", "06:00"), ("6:00", "06:00"), ("6:30", "06:30"), ("23:59", "23:59"),
            ("00:00", "00:00"), ("0:05", "00:05"), ("6", "06:00"), ("06", "06:00"), ("23", "23:00"),
            ("630", "06:30"), ("0630", "06:30"), ("2359", "23:59"), ("6.30", "06:30"), ("6 30", "06:30"),
            ("  07:15  ", "07:15"), ("0", "00:00"),
        ]
        for (raw, expected) in valid {
            let result = parsed(raw)
            check(result == expected, "wake time '\(raw)' → \(expected), got \(result ?? "nil")")
        }
        let invalid = ["", "  ", "24:00", "25", "6:60", "06:75", "99:99", "2400", "12345", "ab", "6:3",
                       "6:300", "123:00", "6:30:00", "-1:00", "6:-5", "٦:٣٠", "+6:30", "6h30", ":30", "6:"]
        for raw in invalid {
            let result = parsed(raw)
            check(result == nil, "wake time '\(raw)' is rejected, got \(result ?? "nil")")
        }
        // Every valid time round-trips through its own text.
        for hour in 0..<24 {
            for minute in 0..<60 {
                let text = TimeInput.text(hour: hour, minute: minute)
                guard let back = TimeInput.parse(text) else { fail("'\(text)' failed to parse"); continue }
                checks += 1
                if back.hour != hour || back.minute != minute { fail("'\(text)' round-trip gave \(back)") }
            }
        }
    }

    // MARK: - Proactive quota alerts

    static let alertNow = Date(timeIntervalSince1970: 1_800_000_000)
    static let fiveHours: TimeInterval = 5 * 3600
    static let oneWeek: TimeInterval = 7 * 86_400

    /// Hand-built snapshot: `used` fractions, resets `resetIn` seconds after `alertNow`.
    static func alertSnapshot(
        used: Double? = nil, resetIn: TimeInterval? = 3600, idle: Bool = false,
        weeklyUsed: Double? = nil, weeklyResetIn: TimeInterval = 3 * 86_400,
        fetchedAt: Date = alertNow, source: String = "Claude OAuth usage"
    ) -> QuotaSnapshot {
        let resetAt = resetIn.map { alertNow.addingTimeInterval($0) }
        let fiveHour = used.map {
            QuotaMetric(name: "5h", usedPercent: $0, remainingPercent: nil, resetAt: resetAt, detail: nil, isIdle: idle)
        }
        let weekly = weeklyUsed.map {
            QuotaMetric(name: "Weekly", usedPercent: $0, remainingPercent: nil,
                        resetAt: alertNow.addingTimeInterval(weeklyResetIn), detail: nil)
        }
        let key = [source, resetAt.map { ISO8601DateFormatter().string(from: $0) } ?? "no-reset"].joined(separator: "|")
        return QuotaSnapshot(tool: .claude, fetchedAt: fetchedAt, primarySource: source, corroboratingSource: nil,
                             fiveHour: fiveHour, weekly: weekly, extras: [], rawWindowKey: key, message: nil)
    }

    static func evaluate(
        _ snapshot: QuotaSnapshot,
        marks: [String: QuotaAlertMark] = [:],
        settings: QuotaAlertSettings = QuotaAlertSettings(),
        now: Date = alertNow
    ) -> QuotaAlertPolicy.Evaluation {
        QuotaAlertPolicy.evaluate(snapshot: snapshot, settings: settings, marks: marks,
                                  fiveHourDuration: fiveHours, weeklyDuration: oneWeek, now: now)
    }

    static func kinds(_ evaluation: QuotaAlertPolicy.Evaluation) -> [QuotaAlertKind] {
        evaluation.alerts.map(\.kind)
    }

    static func testQuotaAlerts() {
        // Thresholds and the cycle control.
        expect(QuotaAlertPolicy.crossedThreshold(used: 79, thresholds: [80, 95]), nil, "79% crosses nothing")
        expect(QuotaAlertPolicy.crossedThreshold(used: 80, thresholds: [80, 95]), 80, "80% crosses 80")
        expect(QuotaAlertPolicy.crossedThreshold(used: 97, thresholds: [95, 80]), 95, "97% announces only the highest")
        expect(QuotaAlertPolicy.crossedThreshold(used: 100, thresholds: [0, 120]), nil, "out-of-range thresholds ignored")
        expect(QuotaAlertSettings.nextThreshold(after: 80), 85, "80% cycles to 85%")
        expect(QuotaAlertSettings.nextThreshold(after: 95), 50, "95% wraps to 50%")
        expect(QuotaAlertSettings.nextThreshold(after: 77), 80, "off-list value snaps to next choice")

        // Settings defaults and persistence.
        let suite = "QuotaWarmerAlertRegression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let stock = QuotaAlertSettings.load(from: defaults)
        expect(stock, QuotaAlertSettings(), "unset defaults load the stock settings")
        expect(stock.sessionThresholds, [80, 95], "default 5h thresholds")
        expect(stock.weeklyThresholds, [75, 90], "default weekly thresholds")
        check(stock.sessionEnabled && stock.weeklyEnabled && stock.paceEnabled, "alerts default on")
        defaults.set(false, forKey: QuotaAlertSettings.paceEnabledKey)
        defaults.set(70, forKey: QuotaAlertSettings.sessionFirstKey)
        defaults.set(85, forKey: QuotaAlertSettings.weeklySecondKey)
        let custom = QuotaAlertSettings.load(from: defaults)
        check(!custom.paceEnabled, "pace toggle persists")
        expect(custom.sessionThresholds, [70, 95], "5h threshold persists")
        expect(custom.weeklyThresholds, [75, 85], "weekly threshold persists")
        let savedMarks = ["session": QuotaAlertMark(windowKey: "k", resetAt: alertNow, level: 80)]
        QuotaAlertMark.save(savedMarks, storageKey: "claude.work", defaults: defaults)
        expect(QuotaAlertMark.load(storageKey: "claude.work", defaults: defaults), savedMarks, "marks round-trip")
        expect(QuotaAlertMark.load(storageKey: "claude", defaults: defaults), [:], "marks are per account")
        check(QuotaAlertMark.defaultsKey(storageKey: "claude.work").hasSuffix(".claude.work"),
              "marks key is wiped with its account")

        // 5h thresholds: once per threshold per window (pace isolated; covered below).
        var thresholdsOnly = QuotaAlertSettings()
        thresholdsOnly.paceEnabled = false
        var marks: [String: QuotaAlertMark] = [:]
        var result = evaluate(alertSnapshot(used: 0.79), settings: thresholdsOnly)
        expect(kinds(result), [], "79% used: no alert")
        result = evaluate(alertSnapshot(used: 0.80), marks: marks, settings: thresholdsOnly)
        expect(kinds(result), [.session], "80% used: session alert")
        expect(result.alerts.first?.usedPercent, 80, "session alert carries used%")
        expect(result.alerts.first?.title(toolName: "Claude Code"), "Claude Code — 80% of 5h quota used", "session title")
        expect(result.alerts.first?.body, "20% left, resets in 1h 0m.", "session body")
        marks = result.marks
        expect(kinds(evaluate(alertSnapshot(used: 0.80), marks: marks, settings: thresholdsOnly)), [], "80% again: deduped")
        expect(kinds(evaluate(alertSnapshot(used: 0.88), marks: marks, settings: thresholdsOnly)), [], "88% in the same window: still deduped")
        result = evaluate(alertSnapshot(used: 0.95), marks: marks, settings: thresholdsOnly)
        expect(kinds(result), [.session], "95% used: second threshold fires")
        marks = result.marks
        expect(kinds(evaluate(alertSnapshot(used: 0.99), marks: marks, settings: thresholdsOnly)), [], "99% after 95%: deduped")
        // Next window (reset 5h later): fires again.
        result = evaluate(alertSnapshot(used: 0.82, resetIn: 3600 + fiveHours,
                                        fetchedAt: alertNow.addingTimeInterval(fiveHours)),
                          marks: marks, settings: thresholdsOnly, now: alertNow.addingTimeInterval(fiveHours))
        expect(kinds(result), [.session], "new window re-arms the 80% alert")

        // Jumping straight past both thresholds announces only the highest, once.
        result = evaluate(alertSnapshot(used: 0.97))
        expect(kinds(result), [.session], "97% from nothing: one alert")
        expect(result.marks["session"]?.level, 95, "jump marks the highest threshold")
        expect(kinds(evaluate(alertSnapshot(used: 0.97), marks: result.marks)), [], "jump is not re-announced at 80%")

        // Disabled / gated cases never alert nor consume the dedup slot.
        var off = QuotaAlertSettings()
        off.sessionEnabled = false
        result = evaluate(alertSnapshot(used: 0.90), settings: off)
        check(!kinds(result).contains(.session), "5h alerts off")
        expectNil(result.marks["session"], "disabled alert leaves no mark")
        expect(kinds(result), [.pace], "pace warning still fires on its own toggle")
        expect(kinds(evaluate(alertSnapshot(used: 0.90, fetchedAt: alertNow.addingTimeInterval(-600)))), [],
               "stale snapshot never alerts")
        expect(kinds(evaluate(alertSnapshot(used: 0.90, resetIn: -60))), [], "passed reset never alerts")
        expect(kinds(evaluate(alertSnapshot(used: 0.90, resetIn: nil))), [], "no reset, no window to dedup on")
        expect(kinds(evaluate(alertSnapshot(used: 0, idle: true))), [], "idle window never alerts")
        // Rollover artifact: 1 min into the window, reads 90% used.
        expect(kinds(evaluate(alertSnapshot(used: 0.90, resetIn: fiveHours - 60))), [],
               "unsettled rollover reading never alerts")

        // Pace: 1h into the window with half the quota gone → runs out in 1h.
        result = evaluate(alertSnapshot(used: 0.50, resetIn: 4 * 3600))
        expect(kinds(result), [.pace], "behind pace: pace alert")
        close(result.alerts.first?.runsOutIn, 3600, "pace projects 1h to run out")
        expect(result.alerts.first?.title(toolName: "Codex"), "Codex — On pace to run out", "pace title")
        expect(result.alerts.first?.body, "Runs out in 1h 0m — before the 5h reset in 4h 0m. 50% used.", "pace body")
        expect(kinds(evaluate(alertSnapshot(used: 0.60, resetIn: 4 * 3600), marks: result.marks)), [],
               "pace alert once per window")
        expect(kinds(evaluate(alertSnapshot(used: 0.30, resetIn: fiveHours - 600))), [],
               "no pace alert in the first 15 minutes")
        expect(kinds(evaluate(alertSnapshot(used: 0.10, resetIn: fiveHours - 1200))), [],
               "no pace alert under 20% used")
        expect(kinds(evaluate(alertSnapshot(used: 0.50, resetIn: 2 * 3600))), [], "on pace: no alert")
        var noPace = QuotaAlertSettings()
        noPace.paceEnabled = false
        expect(kinds(evaluate(alertSnapshot(used: 0.50, resetIn: 4 * 3600), settings: noPace)), [], "pace alert off")
        // Threshold and pace due together: one notification carrying both.
        result = evaluate(alertSnapshot(used: 0.85, resetIn: 3 * 3600))
        expect(kinds(result), [.session], "threshold + pace post a single alert")
        check(result.alerts.first?.runsOutIn != nil, "merged alert carries the run-out")
        check(result.alerts.first?.body.contains("before reset") == true, "merged body mentions the run-out")
        check(result.marks["pace"] != nil, "merged alert consumes the pace slot")
        expect(kinds(evaluate(alertSnapshot(used: 0.86, resetIn: 3 * 3600), marks: result.marks)), [],
               "nothing left to say after the merged alert")
        // The pace projection is the same one the bars show.
        let pace = QuotaPace.compute(quotaLeft: 0.5, resetAt: alertNow.addingTimeInterval(4 * 3600),
                                     windowDuration: fiveHours, now: alertNow, fallbackResetText: "")
        expect(pace.runsOutText, "Runs out in 1h 0m", "bar text matches the alert projection")
        close(pace.runsOutIn, 3600, "QuotaPace exposes the run-out seconds")

        // Weekly thresholds, deduped on the weekly reset.
        expect(kinds(evaluate(alertSnapshot(weeklyUsed: 0.74))), [], "74% weekly: no alert")
        result = evaluate(alertSnapshot(weeklyUsed: 0.75))
        expect(kinds(result), [.weekly], "75% weekly alert")
        expect(result.alerts.first?.title(toolName: "Claude Code"), "Claude Code — 75% of weekly quota used", "weekly title")
        expect(result.alerts.first?.body, "25% left, resets in 3d 0h.", "weekly body")
        marks = result.marks
        expect(kinds(evaluate(alertSnapshot(weeklyUsed: 0.89), marks: marks)), [], "89% weekly: deduped")
        expect(kinds(evaluate(alertSnapshot(weeklyUsed: 0.89, weeklyResetIn: 3 * 86_400 - 2 * 3600), marks: marks)), [],
               "weekly reset drifting 2h is the same window")
        result = evaluate(alertSnapshot(weeklyUsed: 0.90), marks: marks)
        expect(kinds(result), [.weekly], "90% weekly alert")
        expect(kinds(evaluate(alertSnapshot(weeklyUsed: 0.80, weeklyResetIn: 3 * 86_400 + oneWeek), marks: result.marks)),
               [.weekly], "next weekly window re-arms")
        var noWeekly = QuotaAlertSettings()
        noWeekly.weeklyEnabled = false
        expect(kinds(evaluate(alertSnapshot(weeklyUsed: 0.95), settings: noWeekly)), [], "weekly alerts off")
        // 5h and weekly are independent.
        expect(kinds(evaluate(alertSnapshot(used: 0.81, weeklyUsed: 0.76))), [.session, .weekly], "both windows alert")

        // Real parsers. Codex derives its reset from `reset_after_seconds`, so the
        // window key drifts every poll; the alert must not repeat.
        let provider = QuotaProvider()
        func codex(used: Int, resetAfter: Int) -> QuotaSnapshot {
            provider.codexSnapshot(payload: ["rate_limit": [
                "primary_window": ["used_percent": used, "limit_window_seconds": 18000, "reset_after_seconds": resetAfter]
            ]], source: "codex", message: nil)
        }
        let first = codex(used: 85, resetAfter: 3600)
        let drifted = codex(used: 86, resetAfter: 3290)
        check(first.rawWindowKey != drifted.rawWindowKey, "Codex window key drifts between polls")
        result = QuotaAlertPolicy.evaluate(snapshot: first, settings: QuotaAlertSettings(), marks: [:],
                                           fiveHourDuration: fiveHours, weeklyDuration: oneWeek)
        expect(kinds(result), [.session], "Codex 85% used alerts")
        expect(kinds(QuotaAlertPolicy.evaluate(snapshot: drifted, settings: QuotaAlertSettings(), marks: result.marks,
                                               fiveHourDuration: fiveHours, weeklyDuration: oneWeek)), [],
               "drifted Codex key is the same window")
        let idleCodex = codex(used: 0, resetAfter: 18000)
        expect(kinds(QuotaAlertPolicy.evaluate(snapshot: idleCodex, settings: QuotaAlertSettings(), marks: [:],
                                                fiveHourDuration: fiveHours, weeklyDuration: oneWeek)), [],
               "idle Codex window never alerts")
        let claudeReset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let claude = provider.claudeSnapshot(
            payload: ["five_hour": ["utilization": 96, "resets_at": claudeReset],
                      "seven_day": ["utilization": 10, "resets_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(4 * 86_400))]],
            source: "Claude OAuth usage", corroboratingSource: nil, message: nil
        )
        result = QuotaAlertPolicy.evaluate(snapshot: claude, settings: QuotaAlertSettings(), marks: [:],
                                           fiveHourDuration: fiveHours, weeklyDuration: oneWeek)
        expect(kinds(result), [.session], "Claude 96% used: one 5h alert, weekly under threshold")
        expect(result.alerts.map(\.usedPercent), [96], "Claude 96% used alerts with the displayed percent")
        expect(result.marks["session"]?.windowKey, claude.rawWindowKey, "5h mark keyed on rawWindowKey")
    }

    // MARK: - Helpers

    static func fail(_ message: String) { failures.append(message) }

    static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { fail(message) }
    }

    static func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        checks += 1
        if actual != expected { fail("\(message): expected \(expected), got \(actual)") }
    }

    static func expectNil<T>(_ actual: T?, _ message: String) {
        checks += 1
        if let actual { fail("\(message): expected nil, got \(actual)") }
    }

    static func close(_ actual: Double?, _ expected: Double, _ message: String) {
        checks += 1
        guard let actual, abs(actual - expected) < 1e-9 else {
            fail("\(message): expected \(expected), got \(String(describing: actual))"); return
        }
    }
}
