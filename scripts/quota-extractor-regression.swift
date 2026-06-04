import Foundation

@main
struct QuotaExtractorRegression {
    static func main() {
        let provider = QuotaProvider()
        let formatter = ISO8601DateFormatter()
        let sessionReset = Date().addingTimeInterval((4 * 3600) + (57 * 60))
        let weeklyReset = Date().addingTimeInterval(5 * 24 * 3600)

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
}
