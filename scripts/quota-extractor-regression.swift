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
                && ToolID.claude.warmupCommand.contains("--tools ''")
                && ToolID.claude.warmupCommand.contains("--model haiku")
                && !ToolID.claude.warmupCommand.contains("--effort"),
            "Claude warmup should pin Haiku to one no-tool turn without an unsupported effort"
        )
        require(ToolID.claude.fallbackWarmupCommand == nil, "Claude warmup must not fall back to an arbitrary default model")
        require(
            ToolID.codex.warmupCommand.contains("--model gpt-5.6-luna")
                && ToolID.codex.warmupCommand.contains(#"model_reasoning_effort="low""#)
                && ToolID.codex.warmupCommand.contains("--ignore-user-config"),
            "Codex warmup should pin Luna with low reasoning and isolate user config"
        )
        require(ToolID.codex.fallbackWarmupCommand == nil, "Codex warmup must not fall back to a retired or expensive default model")

        let sanitizedFailure = WarmupRunner.sanitizedFailureDetail(
            #"""
            invalid request
Authorization: Bearer secret-token
access_token=private-value
{"refresh_token":"json-private-value"}
"""#
        )
        require(
            sanitizedFailure.contains("invalid request")
                && sanitizedFailure.contains("[REDACTED]")
                && !sanitizedFailure.contains("secret-token")
                && !sanitizedFailure.contains("private-value")
                && !sanitizedFailure.contains("json-private-value"),
            "Warmup failures should preserve actionable bounded detail while redacting credentials"
        )
        require(
            WarmupRunner.sanitizedFailureDetail(String(repeating: "x", count: 1_000), limit: 100).count == 101,
            "Warmup failure detail should be bounded"
        )

        let cliRefreshError = QuotaProviderError.cliRefreshRequired("Claude needs its CLI refresh")
        require(
            cliRefreshError.errorDescription == "Claude needs its CLI refresh",
            "An expired Claude quota credential must be recoverable without reporting a false logout"
        )

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
            liveWindowActive: false,
            sourceFresh: true,
            windowDuration: 5 * 3600
        )
        require(missedSchedule.shouldRun && missedSchedule.caughtUp, "Missed schedule should catch up within horizon")

        let alreadySucceededSchedule = MorningWarmupPolicy.decision(
            now: catchUpNow,
            scheduledAt: scheduledAt,
            dayKey: scheduledDayKey,
            lastSuccessfulDay: scheduledDayKey,
            liveWindowActive: false,
            sourceFresh: true,
            windowDuration: 5 * 3600
        )
        require(!alreadySucceededSchedule.shouldRun, "Per-tool successful scheduled warmup should dedupe same day")

        let unavailableQuotaSource = MorningWarmupPolicy.decision(
            now: catchUpNow,
            scheduledAt: scheduledAt,
            dayKey: scheduledDayKey,
            lastSuccessfulDay: nil,
            liveWindowActive: false,
            sourceFresh: false,
            windowDuration: 5 * 3600
        )
        require(!unavailableQuotaSource.shouldRun, "Unavailable live quota must skip catch-up")

        let activeWindowOverlap = MorningWarmupPolicy.decision(
            now: catchUpNow,
            scheduledAt: scheduledAt,
            dayKey: scheduledDayKey,
            lastSuccessfulDay: nil,
            liveWindowActive: true,
            sourceFresh: true,
            windowDuration: 5 * 3600
        )
        require(!activeWindowOverlap.shouldRun, "Current active local window should skip scheduled catch-up")

        let outsideCatchUpHorizon = MorningWarmupPolicy.decision(
            now: scheduledAt.addingTimeInterval((5 * 3600) + 1),
            scheduledAt: scheduledAt,
            dayKey: scheduledDayKey,
            lastSuccessfulDay: nil,
            liveWindowActive: false,
            sourceFresh: true,
            windowDuration: 5 * 3600
        )
        require(!outsideCatchUpHorizon.shouldRun, "Missed schedule outside the window horizon should not catch up")

        require(
            MorningWarmupPolicy.reservesAutomaticWarmup(
                now: scheduledAt.addingTimeInterval(-(4 * 3600)),
                scheduledAt: scheduledAt,
                windowDuration: 5 * 3600
            ),
            "General auto-warm must preserve the final full quota window before morning warm-up"
        )
        require(
            !MorningWarmupPolicy.reservesAutomaticWarmup(
                now: scheduledAt.addingTimeInterval(-(5 * 3600) - 1),
                scheduledAt: scheduledAt,
                windowDuration: 5 * 3600
            ),
            "General auto-warm may run before the reserved morning window"
        )

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
        // The idle fallback is the absence of a claimed window. It must be
        // claimable by auto-warm, but it cannot confirm success until live quota
        // becomes active. Temporal dedup prevents the sliding projection from
        // sending another warm-up during the claimed five-hour duration.
        require(!claudeIdle.showsActiveWindow(), "Claude idle 5h fallback must not count as an active claimed window")
        require(claudeIdle.canAutoWarm(windowDuration: ToolID.claude.windowDuration),
                "Claude idle 5h window must allow an opted-in auto warmup")
        require(
            AutoWarmDedup.shouldWarm(
                currentWindowKey: claudeIdle.rawWindowKey,
                lastWarmedWindowKey: claudeIdle.rawWindowKey,
                lastWarmedWindowEndsAt: nil,
                currentWindowIsIdle: true,
                now: now
            ),
            "Claude idle window must remain claimable when no warmed duration is active"
        )
        require(
            !AutoWarmDedup.shouldWarm(
                currentWindowKey: claudeIdle.rawWindowKey,
                lastWarmedWindowKey: nil,
                lastWarmedWindowEndsAt: now.addingTimeInterval(ToolID.claude.windowDuration),
                currentWindowIsIdle: true,
                now: now
            ),
            "Claude idle window must not warm again during the already-claimed duration"
        )

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

        testLocalClaudeTokenUsage()
        testLocalClaudeOpenUsageCostCompatibility()
        testCurrentClaudePricing()
        testLocalCodexTokenUsage()
        testCurrentCodexPricingAndUnknownModels()

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

        let credentialStoreSource = readSource("Sources/QuotaWarmer/Services/CredentialStore.swift")
        // LAContext/kSecUseAuthenticationContext governs only the data-protection
        // keychain, so it silenced nothing: background polls kept opening the
        // login-password window (observed 2026-08-20 in the diagnostics log).
        require(
            credentialStoreSource.contains("SecKeychainSetUserInteractionAllowed(false)")
                && credentialStoreSource.contains("allowsUserInteraction")
                && !credentialStoreSource.contains("interactionNotAllowed = true"),
            "Background Claude Keychain reads must be silenced with SecKeychainSetUserInteractionAllowed, not LAContext"
        )
        require(
            credentialStoreSource.contains("SecKeychainSetUserInteractionAllowed(previous.boolValue)"),
            "The process-wide Keychain interaction flag must be restored after a background read"
        )
        // The dialog kept coming back because the item's partition list holds
        // `apple-tool:` while QuotaWarmer's partition is `teamid:…`; "Always
        // Allow" adds a trusted app but never the partition. Reading through the
        // tool the item already trusts is the path that does not prompt, so it
        // has to be tried before the in-process read that does.
        let toolReadIndex = credentialStoreSource.range(of: "securityToolPassword(service: service)")?.lowerBound
        let inProcessReadIndex = credentialStoreSource.range(of: "claudeKeychainPassword(service: service")?.lowerBound
        require(
            toolReadIndex != nil && inProcessReadIndex != nil && toolReadIndex! < inProcessReadIndex!,
            "The prompt-free `security` read must be attempted before the in-process read that can prompt"
        )
        require(
            credentialStoreSource.contains("\"find-generic-password\", \"-w\", \"-s\", service"),
            "The prompt-free Claude read must stay a read-only `security find-generic-password`"
        )
        require(
            credentialStoreSource.contains("if process.isRunning { process.terminate() }"),
            "The `security` read must time out so a stuck Keychain dialog cannot outlive it"
        )
        // Every read that runs on a background poll has to be silenced, not just
        // the Claude one: a foreign Codex item, or a mirror left behind by an
        // older signature, would otherwise open the same password window.
        let unguardedReads = credentialStoreSource.components(separatedBy: .newlines)
            .filter { $0.contains("SecItemCopyMatching(query as CFDictionary, &item)") }
            .filter { !$0.contains("//") }
        require(
            unguardedReads.count == 4,
            "Unexpected number of Keychain reads (\(unguardedReads.count)); each one must be reviewed for dialog suppression"
        )
        require(
            credentialStoreSource.components(separatedBy: "Self.withoutKeychainDialogs {").count - 1 == 3,
            "The mirror, Codex and background Claude reads must all run inside withoutKeychainDialogs"
        )
        // QuotaWarmer mirrors Claude's *access* token into an item it owns, so a
        // relaunch does not re-trigger the macOS approval dialog. The dangerous
        // things that mirror must never do are spelled out below; a blanket ban on
        // Keychain writes would also forbid the safe mirror, so assert the actual
        // invariants instead.
        require(
            credentialStoreSource.contains("Self.claudeCacheService")
                && credentialStoreSource.contains("claudeCacheService = \"com.quotawarmer.app.claude-oauth-cache\""),
            "The Claude credential mirror must live in a Keychain service QuotaWarmer owns"
        )
        for writeCall in ["SecItemAdd", "SecItemUpdate", "SecItemDelete"] {
            for line in credentialStoreSource.components(separatedBy: .newlines)
            where line.contains(writeCall) {
                require(
                    !line.contains("Claude Code-credentials") && !line.contains("claudeKeychainServices"),
                    "Keychain writes must never target Claude Code's own credential item (\(writeCall))"
                )
            }
        }
        require(
            !credentialStoreSource.contains("/v1/oauth/token")
                && !credentialStoreSource.contains("grant_type=refresh_token"),
            "QuotaWarmer must not run a Claude token-refresh chain of its own"
        )
        require(
            credentialStoreSource.contains("struct CachedClaudeCredential")
                && !credentialStoreSource.components(separatedBy: "struct CachedClaudeCredential")[1]
                    .components(separatedBy: "}")[0]
                    .contains("refreshToken"),
            "The mirrored Claude credential must hold only the access token, never the rotating refresh token"
        )
        // The Refresh button was a silent no-op for the whole backoff window: a
        // 4h rate-limit Retry-After pinned the menu bar to a stale reading and
        // every click returned before making a request.
        require(
            appStateSource.contains("if force {\n                clearQuotaBackoff(for: state)"),
            "A user-initiated refresh must clear and bypass the quota rate-limit backoff"
        )
        require(
            appStateSource.contains("func refreshQuotaManually")
                && appStateSource.components(separatedBy: "func refreshQuotaManually")[1]
                    .components(separatedBy: "\n    }")[0]
                    .contains("force: true"),
            "The Refresh button must force its fetch through, not return early on backoff"
        )
        for viewPath in ["Sources/QuotaWarmer/Views/MainTabView.swift", "Sources/QuotaWarmer/Views/MenuContent.swift"] {
            require(
                !readSource(viewPath).contains("appState.refreshQuota(for:"),
                "\(viewPath) must route its Refresh control through refreshQuotaManually"
            )
        }
        // A blocked poll must not make the menu bar lie. While the known reset is
        // still ahead the old numbers stay valid (keep counting down even when the
        // dot is yellow); once it passes, the window rolled over and the old
        // percentage would badly understate the quota actually available.
        require(
            appStateSource.contains("quotaSnapshot?.primaryWindowRolledOver()"),
            "ToolState must derive the rolled-over window from the snapshot"
        )

        // Behavioral coverage for the rollover rule itself: the user's screenshot
        // showed a stale 29% long after that window had already reset.
        let rolloverNow = Date()
        func claudeWindow(resetOffset: TimeInterval) -> QuotaSnapshot {
            provider.snapshot(
                tool: .claude,
                source: "test",
                corroboratingSource: nil,
                payload: [
                    "rate_limits": [
                        "five_hour": [
                            "utilization": 71,
                            "resets_at": Int(rolloverNow.addingTimeInterval(resetOffset).timeIntervalSince1970)
                        ]
                    ]
                ],
                message: nil
            )
        }
        require(
            !claudeWindow(resetOffset: 2 * 3600).primaryWindowRolledOver(now: rolloverNow),
            "A stale snapshot whose reset is still ahead is accurate and must keep its countdown"
        )
        require(
            claudeWindow(resetOffset: -60).primaryWindowRolledOver(now: rolloverNow),
            "Once the known reset has passed the window rolled over and 29% must not be reported as current"
        )
        require(
            !claudeIdle.primaryWindowRolledOver(now: rolloverNow),
            "An idle projection has no real window to roll over"
        )
        let menuBarSource = readSource("Sources/QuotaWarmer/Views/MenuBarLabel.swift")
        require(
            menuBarSource.contains("st.primaryWindowRolledOver")
                && menuBarSource.range(of: "primaryWindowRolledOver")!.lowerBound
                    < menuBarSource.range(of: "Int(metric.remainingFraction * 100)")!.lowerBound,
            "The menu bar must report a rolled-over window as restored before falling back to the stale percentage"
        )
        require(
            !readSource("Sources/QuotaWarmer/Services/QuotaProvider.swift")
                .contains("forHTTPHeaderField: \"User-Agent\""),
            "Must not borrow the Claude Code user agent: measured 2026-08-04, it returns an ~8x longer Retry-After"
        )

        // The bug the user actually hit: forcing the fetch through the backoff in
        // AppState is useless while the control that triggers it is greyed out for
        // the entire retry window, which is precisely when a retry is wanted.
        for viewPath in ["Sources/QuotaWarmer/Views/MainTabView.swift", "Sources/QuotaWarmer/Views/ToolTabView.swift"] {
            let source = readSource(viewPath)
            require(
                !source.contains("isFetchingQuota || state.quotaBackoffActive")
                    && !source.contains("isFetchingQuota || toolState.quotaBackoffActive"),
                "\(viewPath) must not disable Refresh while a quota rate-limit backoff is active"
            )
        }
        require(
            appStateSource.contains("guard tool != .claude || !state.isFetchingQuota else { return }"),
            "Concurrent Claude refresh triggers must collapse to a single in-flight request chain"
        )
        require(
            appStateSource.contains("let shouldAutoWarm = tool == .claude && state(for: tool).isAutoWarmEnabled"),
            "A manual Claude refresh must immediately resume an opted-in auto-warm after credential approval"
        )
        require(
            appStateSource.contains("if tool == .claude { state.isFetchingQuota = false }"),
            "Claude auto-warm must release the outer fetch before post-warm verification"
        )
        let quotaProviderSource = readSource("Sources/QuotaWarmer/Services/QuotaProvider.swift")
        require(
            !quotaProviderSource.contains("credential.isExpired, let refreshed = try?"),
            "An expired Claude credential refresh failure must not be swallowed before another request"
        )
        require(
            quotaProviderSource.contains("QuotaProviderError.cliRefreshRequired")
                && quotaProviderSource.contains("credentialStore.invalidateCachedClaudeCredential()")
                && !quotaProviderSource.contains("/v1/oauth/token"),
            "Expired Claude credentials must defer refresh-token rotation to Claude Code and re-read its fresh credential"
        )
        require(
            !appStateSource.contains("allowsClaudeCLIRecovery")
                && !appStateSource.contains("triggerWarmup(tool: .claude, mode: \"auto\")"),
            "A failed live quota fetch must never spend quota merely to recover Claude credentials"
        )
        require(
            appStateSource.contains("ProcessInfo.processInfo.beginActivity")
                && appStateSource.contains("ProcessInfo.processInfo.endActivity"),
            "Scheduled morning warm-up must hold a bounded activity assertion across short DarkWake sessions"
        )
        require(
            !appStateSource.contains("let cliReady = await applyCLIAuthenticationStatusIfNeeded(for: tool, to: state)")
                && appStateSource.contains("if allowAutomaticWarmup {"),
            "A successful Claude OAuth quota fetch must not be overridden by headless CLI auth status"
        )
        let warmupRunnerSource = readSource("Sources/QuotaWarmer/Services/WarmupRunner.swift")
        require(
            !warmupRunnerSource.contains("switch await claudeAuthenticationStatus(pathPrefix: pathPrefix)"),
            "Claude warmup must let the actual command, not a headless status preflight, determine auth failure"
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

    private static func testLocalClaudeTokenUsage() {
        let provider = LocalUsageProvider(calendar: utcCalendar)
        let now = isoDate("2026-06-15T12:00:00Z")
        let root = temporaryDirectory("claude-local-usage")
        defer { try? FileManager.default.removeItem(at: root) }

        let project = root.appendingPathComponent("project-a")
        createDirectory(project)
        writeJSONL([
            #"{"timestamp":"2026-06-15T10:00:00Z","message":{"id":"msg_today","model":"claude-sonnet-4-20250514","usage":{"input_tokens":1000,"cache_creation_input_tokens":2000,"cache_read_input_tokens":3000,"output_tokens":4000}}}"#,
            #"{"timestamp":"2026-06-15T10:00:01Z","message":{"id":"msg_today","model":"claude-sonnet-4-20250514","usage":{"input_tokens":1000,"cache_creation_input_tokens":2000,"cache_read_input_tokens":3000,"output_tokens":4000}}}"#,
            #"{"timestamp":"2026-06-14T09:00:00Z","message":{"id":"msg_yesterday","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":500,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":500}}}"#
        ], to: project.appendingPathComponent("session.jsonl"))

        let summary = provider.usage(for: .claude, baseURL: root, now: now)
        require(summary.today.totalTokens == 10_000, "Claude local usage should dedupe repeated message ids")
        require(summary.yesterday.totalTokens == 1_000, "Claude local usage should bucket yesterday")
        require(summary.last30Days.totalTokens == 11_000, "Claude local usage should aggregate the last 30 days")
        requireClose(summary.today.costUSD, 0.0714, "Claude local usage should price Sonnet input/cache/output tokens")
        requireClose(summary.yesterday.costUSD, 0.0030, "Claude local usage should price Haiku tokens")
        requireClose(summary.last30Days.costUSD, 0.0744, "Claude local usage should aggregate token cost")
    }

    private static func testLocalClaudeOpenUsageCostCompatibility() {
        let provider = LocalUsageProvider(calendar: utcCalendar)
        let now = isoDate("2026-06-15T12:00:00Z")
        let root = temporaryDirectory("claude-openusage-cost")
        defer { try? FileManager.default.removeItem(at: root) }

        let project = root.appendingPathComponent("project-a")
        createDirectory(project)
        writeJSONL([
            #"{"type":"assistant","data":{"message":{"timestamp":"2026-06-15T08:00:00Z","costUSD":0.42,"message":{"id":"nested_explicit","model":"claude-opus-4-5-20251101","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}}}"#,
            #"{"timestamp":"2026-06-15T09:00:00Z","message":{"id":"modern_opus","model":"claude-opus-4-5-20251101","usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1000}}}"#,
            #"{"timestamp":"2026-06-15T10:00:00Z","message":{"id":"cache_breakdown","model":"claude-sonnet-4-20250514","usage":{"input_tokens":0,"cache_creation_input_tokens":300,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":200},"cache_read_input_tokens":0,"output_tokens":0}}}"#,
            #"{"timestamp":"2026-06-15T11:00:00Z","message":{"id":"fable","model":"claude-fable-5","usage":{"input_tokens":100,"cache_creation_input_tokens":100,"cache_read_input_tokens":100,"output_tokens":100}}}"#
        ], to: project.appendingPathComponent("session.jsonl"))

        let summary = provider.usage(for: .claude, baseURL: root, now: now)
        require(summary.today.totalTokens == 2_702, "Claude local usage should parse OpenUsage-compatible nested records")
        requireClose(summary.today.costUSD, 0.458925, "Claude local usage should apply distinct 5m/1h writes and current Fable rates")
    }

    private static func testCurrentClaudePricing() {
        let provider = LocalUsageProvider(calendar: utcCalendar)
        let now = isoDate("2026-06-15T12:00:00Z")
        let cases: [(String, Double)] = [
            ("claude-fable-5-1", 92.75),
            ("claude-opus-5", 46.75),
            ("claude-sonnet-5", 18.70),
            ("claude-haiku-4-5", 9.35)
        ]

        for (index, entry) in cases.enumerated() {
            let root = temporaryDirectory("claude-current-pricing-\(index)")
            defer { try? FileManager.default.removeItem(at: root) }
            createDirectory(root)
            writeJSONL([
                #"{"timestamp":"2026-06-15T10:00:00Z","message":{"id":"current_\#(index)","model":"\#(entry.0)","usage":{"input_tokens":1000000,"cache_creation":{"ephemeral_5m_input_tokens":1000000,"ephemeral_1h_input_tokens":1000000},"cache_read_input_tokens":1000000,"output_tokens":1000000}}}"#
            ], to: root.appendingPathComponent("session.jsonl"))
            let summary = provider.usage(for: .claude, baseURL: root, now: now)
            requireClose(summary.today.costUSD, entry.1, "Current Claude pricing for \(entry.0)")
        }
    }

    private static func testLocalCodexTokenUsage() {
        let provider = LocalUsageProvider(calendar: utcCalendar)
        let now = isoDate("2026-06-15T12:00:00Z")
        let root = temporaryDirectory("codex-local-usage")
        defer { try? FileManager.default.removeItem(at: root) }

        createDirectory(root)
        writeJSONL([
            #"{"timestamp":"2026-06-15T08:00:00Z","payload":{"type":"session_meta","model":"gpt-5.5"}}"#,
            #"{"timestamp":"2026-06-15T10:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":300,"total_tokens":1300},"total_token_usage":{"input_tokens":100000,"cached_input_tokens":20000,"output_tokens":30000,"total_tokens":130000}}}}"#,
            #"{"timestamp":"2026-06-14T09:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":500,"cached_input_tokens":100,"output_tokens":50,"total_tokens":550},"total_token_usage":{"input_tokens":110000,"cached_input_tokens":21000,"output_tokens":31000,"total_tokens":141000}}}}"#,
            #"{"timestamp":"2026-06-15T11:00:00Z","payload":{"type":"session_meta","model":"codex-auto-review"}}"#,
            #"{"timestamp":"2026-06-15T11:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":50,"output_tokens":10,"total_tokens":110}}}}"#
        ], to: root.appendingPathComponent("session.jsonl"))

        let summary = provider.usage(for: .codex, baseURL: root, now: now)
        require(summary.today.totalTokens == 1_410, "Codex local usage should use per-turn token deltas")
        require(summary.yesterday.totalTokens == 550, "Codex local usage should bucket yesterday")
        require(summary.last30Days.totalTokens == 1_960, "Codex local usage should not aggregate cumulative token totals")
        require(summary.today.costUSD == nil, "Codex local usage with a priced and unpriced model must not report a partial cost")
        requireClose(summary.yesterday.costUSD, 0.00355, "Codex local usage should price yesterday's turn")
        require(summary.last30Days.costUSD == nil, "Codex aggregate cost must remain unavailable when any included model is unpriced")
    }

    private static func testCurrentCodexPricingAndUnknownModels() {
        let provider = LocalUsageProvider(calendar: utcCalendar)
        let now = isoDate("2026-06-15T12:00:00Z")
        let root = temporaryDirectory("codex-current-pricing")
        defer { try? FileManager.default.removeItem(at: root) }
        createDirectory(root)

        var lines: [String] = []
        for (index, model) in ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.6"].enumerated() {
            lines.append(#"{"timestamp":"2026-06-15T0\#(index):00:00Z","payload":{"type":"session_meta","model":"\#(model)"}}"#)
            lines.append(#"{"timestamp":"2026-06-15T0\#(index):01:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100000,"cached_input_tokens":10000,"output_tokens":100000,"total_tokens":200000}}}}"#)
        }
        writeJSONL(lines, to: root.appendingPathComponent("priced.jsonl"))

        let summary = provider.usage(for: .codex, baseURL: root, now: now)
        requireClose(summary.today.costUSD, 12.1582, "Current OpenAI models should use API-equivalent pricing and the gpt-5.6 Sol alias")

        let longContextRoot = temporaryDirectory("codex-long-context")
        defer { try? FileManager.default.removeItem(at: longContextRoot) }
        createDirectory(longContextRoot)
        writeJSONL([
            #"{"timestamp":"2026-06-15T08:00:00Z","payload":{"type":"session_meta","model":"gpt-5.6-luna"}}"#,
            #"{"timestamp":"2026-06-15T08:01:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":300000,"cached_input_tokens":100000,"output_tokens":100000,"total_tokens":400000}}}}"#
        ], to: longContextRoot.appendingPathComponent("long.jsonl"))
        let longContext = provider.usage(for: .codex, baseURL: longContextRoot, now: now)
        requireClose(longContext.today.costUSD, 0.264, "OpenAI inputs over 272K should apply long-context input and output multipliers")

        let mixedRoot = temporaryDirectory("codex-mixed-pricing")
        defer { try? FileManager.default.removeItem(at: mixedRoot) }
        createDirectory(mixedRoot)
        writeJSONL([
            #"{"timestamp":"2026-06-15T08:00:00Z","payload":{"type":"session_meta","model":"gpt-5.6-luna"}}"#,
            #"{"timestamp":"2026-06-15T08:01:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":1000,"total_tokens":2000}}}}"#,
            #"{"timestamp":"2026-06-15T09:00:00Z","payload":{"type":"session_meta","model":"future-unpriced-model"}}"#,
            #"{"timestamp":"2026-06-15T09:01:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":1000,"total_tokens":2000}}}}"#
        ], to: mixedRoot.appendingPathComponent("mixed.jsonl"))
        let mixed = provider.usage(for: .codex, baseURL: mixedRoot, now: now)
        require(mixed.today.costUSD == nil, "A mixed priced/unpriced bucket must remain unavailable, not partially priced")
        require(mixed.last30Days.costUSD == nil, "An aggregate containing unpriced usage must remain unavailable")
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func isoDate(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: text) else {
            fatalError("Invalid fixture date \(text)")
        }
        return date
    }

    private static func temporaryDirectory(_ prefix: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotawarmer-\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }

    private static func createDirectory(_ url: URL) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            fatalError("Could not create fixture directory \(url.path): \(error)")
        }
    }

    private static func writeJSONL(_ lines: [String], to url: URL) {
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            fatalError("Could not write fixture \(url.path): \(error)")
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
