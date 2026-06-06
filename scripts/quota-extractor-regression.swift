import Foundation

@main
struct QuotaExtractorRegression {
    static func main() {
        let provider = QuotaProvider()
        let formatter = ISO8601DateFormatter()
        let sessionReset = Date().addingTimeInterval((4 * 3600) + (57 * 60))
        let weeklyReset = Date().addingTimeInterval(5 * 24 * 3600)

        let loggedOutAuth = ClaudeCLIAuthSnapshot.parse("""
        {"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}
        """)
        require(loggedOutAuth?.loggedIn == false, "Claude auth status should parse logged-out JSON")
        require(loggedOutAuth?.authMethod == "none", "Claude auth status should parse auth method")

        let loggedInAuth = ClaudeCLIAuthSnapshot.parse("""
        {"loggedIn":true,"authMethod":"oauth","apiProvider":"firstParty"}
        """)
        require(loggedInAuth?.loggedIn == true, "Claude auth status should parse logged-in JSON")
        require(
            ToolID.claude.warmupCommand.contains("--max-turns 1")
                && ToolID.claude.warmupCommand.contains("--tools ''"),
            "Claude warmup should be bounded to one no-tool turn"
        )
        require(ToolID.claude.fallbackWarmupCommand != nil, "Claude warmup should have a default-model fallback")

        let codexPayload: [String: Any] = [
            "data": [
                "limits": [
                    [
                        "label": "5 hour usage limit",
                        "remaining": 99,
                        "limit": 100,
                        "resets_at": formatter.string(from: sessionReset)
                    ],
                    [
                        "label": "Weekly usage limit",
                        "remaining_percent": 60,
                        "resets_at": formatter.string(from: weeklyReset)
                    ]
                ]
            ]
        ]
        let codex = provider.snapshot(
            tool: .codex,
            source: "test",
            corroboratingSource: nil,
            payload: codexPayload,
            message: nil
        )
        requireClose(codex.fiveHour?.remainingFraction, 0.99, "Codex 5h remaining")
        requireClose(codex.weekly?.remainingFraction, 0.60, "Codex weekly remaining")
        require(codex.fiveHour?.resetAt != nil, "Codex 5h reset should be extracted")

        // Real Codex `wham/usage` shape: used_percent is on a 0–100 scale, so
        // 1 means 1% used (99% remaining). The generic extractor would mis-read
        // a value of 1 as 100% used; the dedicated parser must not.
        let whamPayload: [String: Any] = [
            "rate_limit": [
                "primary_window": [
                    "used_percent": 1,
                    "limit_window_seconds": 18000,
                    "reset_after_seconds": 13466,
                    "reset_at": Int(sessionReset.timeIntervalSince1970)
                ],
                "secondary_window": [
                    "used_percent": 0,
                    "limit_window_seconds": 604800,
                    "reset_at": Int(weeklyReset.timeIntervalSince1970)
                ]
            ]
        ]
        let wham = provider.codexSnapshot(payload: whamPayload, source: "test", message: nil)
        requireClose(wham.fiveHour?.remainingFraction, 0.99, "Codex wham 5h remaining (1% used)")
        requireClose(wham.weekly?.remainingFraction, 1.0, "Codex wham weekly remaining (0% used)")
        require(wham.fiveHour?.resetAt != nil, "Codex wham 5h reset should be extracted")
        require(wham.fiveHour?.name == "5h", "Codex wham primary window should be 5h")
        require(wham.weekly?.name == "Weekly", "Codex wham secondary window should be weekly")

        var whamLaterPayload = whamPayload
        var whamLaterRateLimit = whamLaterPayload["rate_limit"] as! [String: Any]
        var whamLaterPrimary = whamLaterRateLimit["primary_window"] as! [String: Any]
        whamLaterPrimary["used_percent"] = 5
        whamLaterRateLimit["primary_window"] = whamLaterPrimary
        whamLaterPayload["rate_limit"] = whamLaterRateLimit
        let whamLater = provider.codexSnapshot(payload: whamLaterPayload, source: "test", message: nil)
        require(wham.rawWindowKey == whamLater.rawWindowKey, "Codex window key should not change as usage changes")

        let now = Date()
        let freshWindowPayload: [String: Any] = [
            "rate_limit": [
                "primary_window": [
                    "used_percent": 1,
                    "limit_window_seconds": 18000,
                    "reset_at": Int(now.addingTimeInterval((5 * 3600) - 120).timeIntervalSince1970)
                ]
            ]
        ]
        let freshWindow = provider.codexSnapshot(payload: freshWindowPayload, source: "test", message: nil)
        require(
            freshWindow.canAutoWarm(now: now, windowDuration: 5 * 3600),
            "Fresh window should allow auto warmup"
        )

        let alreadyActiveWindowPayload: [String: Any] = [
            "rate_limit": [
                "primary_window": [
                    "used_percent": 5,
                    "limit_window_seconds": 18000,
                    "reset_at": Int(now.addingTimeInterval((4 * 3600) + (20 * 60)).timeIntervalSince1970)
                ]
            ]
        ]
        let alreadyActiveWindow = provider.codexSnapshot(payload: alreadyActiveWindowPayload, source: "test", message: nil)
        require(
            !alreadyActiveWindow.canAutoWarm(now: now, windowDuration: 5 * 3600),
            "Already-active window should not allow auto warmup just because remaining is high"
        )

        let scheduledAt = Date(timeIntervalSince1970: 1_780_560_000)
        let scheduledDayKey = "2026-6-4"
        let catchUpNow = scheduledAt.addingTimeInterval(3 * 3600)
        let missedSchedule = MorningWarmupPolicy.decision(
            now: catchUpNow,
            scheduledAt: scheduledAt,
            dayKey: scheduledDayKey,
            lastSuccessfulDay: nil,
            lastActivity: scheduledAt.addingTimeInterval(-3600),
            activeWindowStartedAt: nil,
            windowDuration: 5 * 3600
        )
        require(missedSchedule.shouldRun && missedSchedule.caughtUp, "Missed schedule should catch up within horizon")

        let alreadySucceededSchedule = MorningWarmupPolicy.decision(
            now: catchUpNow,
            scheduledAt: scheduledAt,
            dayKey: scheduledDayKey,
            lastSuccessfulDay: scheduledDayKey,
            lastActivity: nil,
            activeWindowStartedAt: nil,
            windowDuration: 5 * 3600
        )
        require(!alreadySucceededSchedule.shouldRun, "Per-tool successful scheduled warmup should dedupe same day")

        let userStartedAfterSchedule = MorningWarmupPolicy.decision(
            now: catchUpNow,
            scheduledAt: scheduledAt,
            dayKey: scheduledDayKey,
            lastSuccessfulDay: nil,
            lastActivity: scheduledAt.addingTimeInterval(60),
            activeWindowStartedAt: nil,
            windowDuration: 5 * 3600
        )
        require(!userStartedAfterSchedule.shouldRun, "User activity after scheduled time should skip catch-up")

        let activeWindowOverlap = MorningWarmupPolicy.decision(
            now: catchUpNow,
            scheduledAt: scheduledAt,
            dayKey: scheduledDayKey,
            lastSuccessfulDay: nil,
            lastActivity: scheduledAt.addingTimeInterval(-30 * 60),
            activeWindowStartedAt: scheduledAt.addingTimeInterval(-30 * 60),
            windowDuration: 5 * 3600
        )
        require(!activeWindowOverlap.shouldRun, "Current active local window should skip scheduled catch-up")

        let outsideCatchUpHorizon = MorningWarmupPolicy.decision(
            now: scheduledAt.addingTimeInterval((5 * 3600) + 1),
            scheduledAt: scheduledAt,
            dayKey: scheduledDayKey,
            lastSuccessfulDay: nil,
            lastActivity: nil,
            activeWindowStartedAt: nil,
            windowDuration: 5 * 3600
        )
        require(!outsideCatchUpHorizon.shouldRun, "Missed schedule outside the window horizon should not catch up")

        require(
            MorningWarmupPolicy.resolvedLastSuccessfulDay(
                perToolDay: nil,
                legacyDay: scheduledDayKey,
                currentDay: scheduledDayKey
            ) == scheduledDayKey,
            "Legacy morning warm day should preserve today's dedup during migration"
        )
        require(
            MorningWarmupPolicy.resolvedLastSuccessfulDay(
                perToolDay: nil,
                legacyDay: "2026-6-3",
                currentDay: scheduledDayKey
            ) == nil,
            "Legacy morning warm day should not migrate stale days"
        )
        require(
            MorningWarmupPolicy.resolvedLastSuccessfulDay(
                perToolDay: scheduledDayKey,
                legacyDay: nil,
                currentDay: scheduledDayKey
            ) == scheduledDayKey,
            "Per-tool morning warm day should remain authoritative"
        )

        let postWarmFetchedAt = now.addingTimeInterval(2)
        let postWarmSnapshot = QuotaSnapshot(
            tool: .codex,
            fetchedAt: postWarmFetchedAt,
            primarySource: "test",
            corroboratingSource: nil,
            fiveHour: nil,
            weekly: nil,
            extras: [],
            rawWindowKey: "test|post-warm-window",
            message: nil
        )
        require(
            postWarmSnapshot.isClaimableAutoWindow(previousFetchedAt: now, now: postWarmFetchedAt.addingTimeInterval(1)),
            "Scheduled warmup should claim a fresh post-warm quota window"
        )

        let unchangedSnapshot = QuotaSnapshot(
            tool: .codex,
            fetchedAt: now,
            primarySource: "test",
            corroboratingSource: nil,
            fiveHour: nil,
            weekly: nil,
            extras: [],
            rawWindowKey: "test|old-window",
            message: nil
        )
        require(
            !unchangedSnapshot.isClaimableAutoWindow(previousFetchedAt: now, now: postWarmFetchedAt),
            "Scheduled warmup should not claim an unchanged quota snapshot"
        )

        let stalePostWarmSnapshot = QuotaSnapshot(
            tool: .codex,
            fetchedAt: now.addingTimeInterval(-31 * 60),
            primarySource: "test",
            corroboratingSource: nil,
            fiveHour: nil,
            weekly: nil,
            extras: [],
            rawWindowKey: "test|stale-window",
            message: nil
        )
        require(
            !stalePostWarmSnapshot.isClaimableAutoWindow(previousFetchedAt: nil, now: now),
            "Scheduled warmup should not claim stale quota snapshots"
        )

        let claudePayload: [String: Any] = [
            "plan_usage_limits": [
                [
                    "period": "Current session",
                    "usage_percent": 81,
                    "reset_at": formatter.string(from: sessionReset)
                ],
                [
                    "period": "Weekly limits All models",
                    "used_percent": 11,
                    "reset_at": formatter.string(from: weeklyReset)
                ]
            ]
        ]
        let claude = provider.snapshot(
            tool: .claude,
            source: "test",
            corroboratingSource: nil,
            payload: claudePayload,
            message: nil
        )
        requireClose(claude.fiveHour?.remainingFraction, 0.19, "Claude current-session remaining")
        requireClose(claude.weekly?.remainingFraction, 0.89, "Claude weekly remaining")

        // Claude OAuth usage emits ISO timestamps with fractional seconds and a
        // five_hour/seven_day shape — the reset must still be parsed.
        let claudeFractionalPayload: [String: Any] = [
            "five_hour": [
                "utilization": 22.0,
                "resets_at": "2026-06-04T11:10:00.973380+00:00"
            ],
            "seven_day": [
                "utilization": 17.0,
                "resets_at": "2026-06-09T20:00:00.973402+00:00"
            ]
        ]
        let claudeFractional = provider.snapshot(
            tool: .claude,
            source: "test",
            corroboratingSource: nil,
            payload: claudeFractionalPayload,
            message: nil
        )
        requireClose(claudeFractional.fiveHour?.remainingFraction, 0.78, "Claude five_hour remaining")
        require(claudeFractional.fiveHour?.resetAt != nil, "Claude fractional-seconds reset must parse")
        require(claudeFractional.weekly?.resetAt != nil, "Claude seven_day reset must parse")

        let claudeZeroUtilizationPayload: [String: Any] = [
            "five_hour": [
                "utilization": 0,
                "resets_at": "2026-06-05T16:20:01.015861+00:00"
            ],
            "seven_day": [
                "utilization": 27,
                "resets_at": "2026-06-09T20:00:01.015888+00:00"
            ]
        ]
        let claudeZeroUtilization = provider.claudeSnapshot(
            payload: claudeZeroUtilizationPayload,
            source: "Claude OAuth usage",
            corroboratingSource: nil,
            message: nil
        )
        requireClose(claudeZeroUtilization.fiveHour?.remainingFraction, 1.0, "Claude zero-utilization 5h remaining")
        require(claudeZeroUtilization.fiveHour?.resetAt != nil, "Claude zero-utilization 5h reset must parse")
        require(
            claudeZeroUtilization.fiveHour?.context != "5h idle window",
            "Claude zero-utilization active 5h window must not be converted to idle fallback"
        )
        requireClose(claudeZeroUtilization.weekly?.remainingFraction, 0.73, "Claude zero-utilization weekly remaining")

        let claudeRateLimitsPayload: [String: Any] = [
            "rate_limits": [
                "five_hour": [
                    "utilization": 81,
                    "resets_at": Int(sessionReset.timeIntervalSince1970)
                ],
                "seven_day": [
                    "utilization": 11,
                    "resets_at": Int(weeklyReset.timeIntervalSince1970)
                ]
            ]
        ]
        let claudeRateLimits = provider.snapshot(
            tool: .claude,
            source: "test",
            corroboratingSource: nil,
            payload: claudeRateLimitsPayload,
            message: nil
        )
        requireClose(claudeRateLimits.fiveHour?.remainingFraction, 0.19, "Claude rate_limits five_hour remaining")
        requireClose(claudeRateLimits.weekly?.remainingFraction, 0.89, "Claude rate_limits seven_day remaining")

        // Claude reports "no active 5h window" as an explicit null `five_hour`
        // (the user hasn't touched Claude in 5h). The app must surface that as an
        // idle, fully-available window — never a blank "--".
        let claudeIdlePayload: [String: Any] = [
            "five_hour": NSNull(),
            "seven_day": [
                "utilization": 26.0,
                "resets_at": formatter.string(from: weeklyReset)
            ]
        ]
        let claudeIdle = provider.claudeSnapshot(
            payload: claudeIdlePayload,
            source: "Claude OAuth usage",
            corroboratingSource: nil,
            message: nil
        )
        require(claudeIdle.fiveHour != nil, "Claude idle 5h window must surface a metric, not nil")
        requireClose(claudeIdle.fiveHour?.remainingFraction, 1.0, "Claude idle 5h window reads fully available")
        require(claudeIdle.fiveHour?.resetAt == nil, "Claude idle 5h window has no reset")
        requireClose(claudeIdle.weekly?.remainingFraction, 0.74, "Claude idle weekly still parses")

        // A populated five_hour must still parse normally through claudeSnapshot.
        let claudeActive = provider.claudeSnapshot(
            payload: claudeFractionalPayload,
            source: "Claude OAuth usage",
            corroboratingSource: nil,
            message: nil
        )
        requireClose(claudeActive.fiveHour?.remainingFraction, 0.78, "Claude active 5h still parses via claudeSnapshot")

        let genericRemainingPayload: [String: Any] = [
            "limits": [
                [
                    "window": "5h current remaining",
                    "percent": 99,
                    "resets_in": 17_820
                ]
            ]
        ]
        let generic = provider.snapshot(
            tool: .codex,
            source: "test",
            corroboratingSource: nil,
            payload: genericRemainingPayload,
            message: nil
        )
        requireClose(generic.fiveHour?.remainingFraction, 0.99, "Generic remaining-percent context")
        require(generic.fiveHour?.resetAt != nil, "Relative reset should be extracted")

        let empty = provider.snapshot(
            tool: .claude,
            source: "test",
            corroboratingSource: nil,
            payload: ["status": "ok"],
            message: nil
        )
        require(empty.fiveHour == nil, "Missing quota fields should not fabricate a 5h metric")
        require(empty.weekly == nil, "Missing quota fields should not fabricate a weekly metric")

        let visibleReadySources = [
            "Sources/QuotaWarmer/Views/MenuBarLabel.swift",
            "Sources/QuotaWarmer/Views/ToolTabView.swift",
            "Sources/QuotaWarmer/Views/MenuContent.swift"
        ]
        for sourcePath in visibleReadySources {
            let source = readSource(sourcePath)
            require(!source.contains("\"ready\""), "\(sourcePath) must not render a lowercase ready status")
            require(!source.contains("\"Ready\""), "\(sourcePath) must not render an uppercase Ready status")
        }

        let appStateSource = readSource("Sources/QuotaWarmer/AppState.swift")
        require(
            appStateSource.contains("if state.primaryMetric?.resetAt == nil")
                && appStateSource.contains("state.rememberConfirmedWarmup(startedAt: result.date, duration: tool.windowDuration)"),
            "Successful warmup must persist a confirmed reset fallback when live quota has no reset"
        )

        print("quota extractor regression tests passed")
    }

    private static func require(_ condition: Bool, _ message: String) {
        guard condition else {
            fatalError(message)
        }
    }

    private static func requireClose(_ actual: Double?, _ expected: Double, _ message: String) {
        guard let actual, abs(actual - expected) < 0.0001 else {
            fatalError("\(message): expected \(expected), got \(String(describing: actual))")
        }
    }

    private static func readSource(_ relativePath: String) -> String {
        let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(relativePath)
            .path
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            fatalError("Could not read source file at \(relativePath)")
        }
        return source
    }
}
