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

        // An idle (not-yet-started) Codex 5h window reports the full window length
        // as `reset_after_seconds` and a `reset_at` of now + the full window — a
        // sliding "if you started now" projection. It is a genuine, claimable
        // window: warming it (sending `hi`) is exactly the point, so auto-warm IS
        // allowed. The stable "idle" key plus `lastAutoWarmWindowEndsAt` prevent the
        // re-warm-every-poll storm, not a blanket exclusion from auto-warm.
        let idleWindowPayload: [String: Any] = [
            "rate_limit": [
                "primary_window": [
                    "used_percent": 1,
                    "limit_window_seconds": 18000,
                    "reset_after_seconds": 18000,
                    "reset_at": Int(now.addingTimeInterval(5 * 3600).timeIntervalSince1970)
                ]
            ]
        ]
        let idleWindow = provider.codexSnapshot(payload: idleWindowPayload, source: "test", message: nil)
        // The projected reset is still surfaced for display (the web shows it too)…
        require(idleWindow.fiveHour?.resetAt != nil, "Idle Codex 5h window should still surface its projected reset for display")
        require(idleWindow.fiveHour?.isIdle == true, "Idle Codex 5h window must be flagged idle")
        require(idleWindow.fiveHour?.isIdleFiveHourWindow == true, "Idle Codex 5h window must read as an idle 5h window")
        // It IS claimable, so auto-warm is allowed (this is the whole point for
        // Codex — open the not-yet-started window)…
        require(
            idleWindow.canAutoWarm(now: now, windowDuration: 5 * 3600),
            "Idle (not-yet-started) Codex window must allow auto warmup"
        )
        // …but until the window actually opens, it must not *confirm* a claim.
        require(
            !idleWindow.showsActiveWindow(now: now),
            "Idle (sliding-reset) Codex window must not confirm a phantom warm-up claim"
        )
        require(idleWindow.rawWindowKey == "test|idle", "Idle Codex window key must be stable (not the sliding reset)")

        // Auto-warm dedup for idle windows must ignore the stable "idle" key and
        // gate purely on the just-warmed window's end time. Otherwise a stored
        // "…|idle" key (e.g. left by an older build, or the previous idle period)
        // would permanently block claiming every later idle window.
        require(
            AutoWarmDedup.shouldWarm(
                currentWindowKey: "test|idle",
                lastWarmedWindowKey: "test|idle",
                lastWarmedWindowEndsAt: nil,
                currentWindowIsIdle: true,
                now: now
            ),
            "Idle window with a stale matching key but no live warmed-window end must be claimable"
        )
        require(
            !AutoWarmDedup.shouldWarm(
                currentWindowKey: "test|idle",
                lastWarmedWindowKey: "test|idle",
                lastWarmedWindowEndsAt: now.addingTimeInterval(3600),
                currentWindowIsIdle: true,
                now: now
            ),
            "Idle window must not re-warm while the just-claimed window is still open"
        )
        // A non-idle window keeps the strict key dedup (same active window key blocks).
        require(
            !AutoWarmDedup.shouldWarm(
                currentWindowKey: "test|2026-01-01T00:00:00Z",
                lastWarmedWindowKey: "test|2026-01-01T00:00:00Z",
                lastWarmedWindowEndsAt: nil,
                currentWindowIsIdle: false,
                now: now
            ),
            "Active window with a matching key must remain deduped"
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

        // After a 5h window expires (and before the next request opens one), the
        // OAuth API returns a *populated* five_hour with no `resets_at`:
        // `{ utilization: 0, resets_at: null }`. That parses as a real, reset-less
        // metric at 100% left — leaving the UI with a 5h percentage but no
        // countdown, which made the menu bar fall back to the weekly window. It
        // must be surfaced as the idle 5h window (projected reset) instead.
        let claudeResetlessPayload: [String: Any] = [
            "five_hour": [
                "utilization": 0,
                "resets_at": NSNull()
            ],
            "seven_day": [
                "utilization": 27,
                "resets_at": "2026-06-09T20:00:01.015888+00:00"
            ]
        ]
        let claudeResetless = provider.claudeSnapshot(
            payload: claudeResetlessPayload,
            source: "Claude OAuth usage",
            corroboratingSource: nil,
            message: nil
        )
        require(claudeResetless.fiveHour?.isIdle == true,
                "Reset-less full Claude 5h window must be surfaced as idle")
        require(claudeResetless.fiveHour?.resetAt != nil,
                "Reset-less Claude 5h window must surface a projected reset so the menu bar shows a 5h countdown, not the weekly window")
        require(claudeResetless.rawWindowKey == "Claude OAuth usage|idle",
                "Reset-less Claude 5h window must use the stable idle key")
        requireClose(claudeResetless.fiveHour?.remainingFraction, 1.0, "Reset-less Claude 5h window reads fully available")

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
        require(claudeIdle.fiveHour?.isIdle == true, "Claude idle 5h window must be flagged idle")
        require(claudeIdle.fiveHour?.isIdleFiveHourWindow == true, "Claude idle 5h window must read as an idle 5h window")
        // The idle window now carries a *projected* (sliding "if you started now")
        // reset of now + windowDuration so the menu bar/panel show a countdown
        // instead of a bare "100%". It must be in the future and ~5h out.
        require(claudeIdle.fiveHour?.resetAt != nil, "Claude idle 5h window must surface a projected reset for display")
        if let idleReset = claudeIdle.fiveHour?.resetAt {
            let projected = idleReset.timeIntervalSinceNow
            require(projected > 4.5 * 3600 && projected <= 5 * 3600 + 5,
                    "Claude idle 5h projected reset must be ~5h out, was \(projected)s")
        }
        // The projection slides every poll, so the dedup key must be the stable
        // "idle" marker, never the moving timestamp.
        require(claudeIdle.rawWindowKey == "Claude OAuth usage|idle",
                "Claude idle window key must be stable (not the sliding reset)")
        requireClose(claudeIdle.weekly?.remainingFraction, 0.74, "Claude idle weekly still parses")
        // The idle fallback is the *absence* of a claimed window — it must never
        // confirm a warm-up or auto-warm, otherwise a warm that didn't actually
        // open a window would read as "Window claimed", and the sliding projection
        // would make the app warm a phantom window on every poll.
        require(!claudeIdle.showsActiveWindow(), "Claude idle 5h fallback must not count as an active claimed window")
        require(!claudeIdle.canAutoWarm(windowDuration: ToolID.claude.windowDuration),
                "Claude idle 5h window (sliding projection) must not allow auto warmup")

        // A freshly-warmed window carries a live reset in the future and *must*
        // confirm the warm-up claim.
        let claudeActiveWindowPayload: [String: Any] = [
            "five_hour": [
                "utilization": 1.0,
                "resets_at": formatter.string(from: sessionReset)
            ],
            "seven_day": [
                "utilization": 20.0,
                "resets_at": formatter.string(from: weeklyReset)
            ]
        ]
        let claudeActiveWindow = provider.claudeSnapshot(
            payload: claudeActiveWindowPayload,
            source: "Claude OAuth usage",
            corroboratingSource: nil,
            message: nil
        )
        require(claudeActiveWindow.showsActiveWindow(), "A live future-reset 5h window must confirm a warm-up claim")
        // The regression that motivated this: utilization is a 0–100 scale, so a
        // freshly-warmed window at 1% used must read as 99% left — not 0% (which
        // happened when `utilization: 1.0` was misread as a 0–1 fraction).
        requireClose(claudeActiveWindow.fiveHour?.remainingFraction, 0.99, "utilization 1.0 means 1% used (99% left), not 100% used")

        // Right at a window rollover the API can pair the *new* window's reset
        // (just opened, ~5h left) with the just-ended window's high utilization
        // (reads as ~0% left). That's physically impossible in the first minutes,
        // so it must be flagged as an unsettled artifact (UI shows "settling").
        let claudeRolloverArtifactPayload: [String: Any] = [
            "five_hour": [
                "utilization": 99.0,
                "resets_at": formatter.string(from: sessionReset)
            ],
            "seven_day": [
                "utilization": 9.0,
                "resets_at": formatter.string(from: weeklyReset)
            ]
        ]
        let claudeRollover = provider.claudeSnapshot(
            payload: claudeRolloverArtifactPayload,
            source: "Claude OAuth usage",
            corroboratingSource: nil,
            message: nil
        )
        require(
            claudeRollover.isUnsettledRolloverReading(windowDuration: ToolID.claude.windowDuration),
            "A just-opened 5h window reading ~0% left must be flagged as an unsettled rollover artifact"
        )
        // A genuinely active window (settled, plenty left) must NOT be flagged.
        require(
            !claudeActiveWindow.isUnsettledRolloverReading(windowDuration: ToolID.claude.windowDuration),
            "A settled active window with quota left must not be treated as a rollover artifact"
        )
        // The idle (null five_hour) fallback is a separate state and must not be
        // flagged as a rollover artifact either (its reset is an idle projection,
        // not a freshly-opened window).
        require(
            !claudeIdle.isUnsettledRolloverReading(windowDuration: ToolID.claude.windowDuration),
            "Idle 5h fallback must not be treated as a rollover artifact"
        )

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
            appStateSource.contains("liveMetric?.resetAt == nil || liveMetric?.isIdle == true")
                && appStateSource.contains("state.rememberConfirmedWarmup(startedAt: result.date, duration: tool.windowDuration)"),
            "Successful warmup must persist a confirmed reset fallback when live quota has no real (non-idle) reset"
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
