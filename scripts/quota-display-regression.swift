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
