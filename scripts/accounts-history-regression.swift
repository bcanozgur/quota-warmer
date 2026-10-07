import Foundation

/// Regression suite for multi-account identity (`Models/ProviderAccount.swift`)
/// and quota history (`Models/UsageHistory.swift`, the daily/hourly token data
/// from `LocalUsageProvider`). Compiled standalone like the other regression
/// scripts (see .github/workflows/ci.yml).
@main
struct AccountsHistoryRegression {
    nonisolated(unsafe) static var failures: [String] = []
    nonisolated(unsafe) static var checks = 0

    static func main() async {
        DebugLevel.current = .off
        // Price from the repo's catalog files, never the network or a user cache.
        for tool in ToolID.allCases {
            let store = ModelCatalogStore.shared(for: tool)
            store.remoteRefreshEnabled = false
            let path = "Sources/QuotaWarmer/Resources/\(ModelCatalogStore.resourceName(for: tool)).json"
            let catalog = try? ModelCatalog.decode(Data(contentsOf: URL(fileURLWithPath: path)))
            check(catalog.map { store.adopt($0, source: "repo") } == true, "repo \(tool) catalog loads")
        }
        testProviderIdentity()
        testAccountEnvironment()
        testKeychainServiceNames()
        testAccountValidation()
        testQuotaSample()
        testWindowGrouping()
        testSampleSpacing()
        testChartSegments()
        testHistoryStore()
        testDailyAndHourlyTokens()

        if failures.isEmpty {
            print("Accounts & history regressions passed (\(checks) checks)")
        } else {
            for failure in failures { print("FAIL: \(failure)") }
            print("\(failures.count) of \(checks) accounts/history checks failed")
            exit(1)
        }
    }

    // MARK: - Accounts

    static func testProviderIdentity() {
        let claude = ProviderID.default(.claude)
        expect(claude.storageKey, "claude", "default account keeps the pre-multi-account key")
        expect(ProviderID.default(.codex).storageKey, "codex", "default Codex keeps its key")
        expect(claude.rawValue, "claude", "rawValue mirrors storageKey for existing defaults keys")
        check(claude.home == nil && claude.isDefault, "default account has no home override")
        expect(claude.shortName, "Claude", "default account shows the plain tool name")
        check(claude.badge == nil, "default account has no badge")

        let work = ProviderAccount(id: "work", kind: .claude, name: "Work", home: "/Users/test/.claude-work").providerID
        expect(work.storageKey, "claude.work", "added account key is namespaced")
        expect(work.shortName, "Claude · Work", "added account shows its name")
        expect(work.badge, "W", "badge is the name's initial")
        check(work != claude, "accounts of one tool are distinct")

        var renamed = work
        renamed.name = "Office"
        check(renamed == work && renamed.hashValue == work.hashValue, "renaming keeps identity (dictionary key)")
        var dict: [ProviderID: Int] = [work: 1]
        dict[renamed] = 2
        expect(dict.count, 1, "renamed account replaces, not duplicates, its entry")

        let forcedHome = ProviderID(kind: .claude, accountID: ProviderID.defaultAccountID, home: "/tmp/x")
        check(forcedHome.home == nil, "the default account can never carry a home override")

        let personalCodex = ProviderAccount(id: "work", kind: .codex, name: "Work", home: "/Users/test/.codex-work").providerID
        check(personalCodex != work, "same account id under another tool is a different account")
    }

    static func testAccountEnvironment() {
        let work = ProviderAccount(id: "work", kind: .claude, name: "Work", home: "/Users/test/.claude-work").providerID
        expect(work.cliEnvironment, ["CLAUDE_CONFIG_DIR": "/Users/test/.claude-work"], "Claude account exports CLAUDE_CONFIG_DIR")
        expect(work.loginCommand, "CLAUDE_CONFIG_DIR='/Users/test/.claude-work' claude auth login", "Claude login command")
        expect(WarmupRunner.environmentPrefix(for: work), "CLAUDE_CONFIG_DIR='/Users/test/.claude-work' ", "warm-up prefix")
        expect(work.logDirectoryURL?.path, "/Users/test/.claude-work/projects", "Claude account logs live in its home")

        let codex = ProviderAccount(id: "side", kind: .codex, name: "Side", home: "/Users/test/.codex side").providerID
        expect(codex.cliEnvironment, ["CODEX_HOME": "/Users/test/.codex side"], "Codex account exports CODEX_HOME")
        expect(codex.loginCommand, "CODEX_HOME='/Users/test/.codex side' codex login", "Codex login command quotes spaces")
        expect(codex.logDirectoryURL?.path, "/Users/test/.codex side/sessions", "Codex account logs live in its home")

        let claude = ProviderID.default(.claude)
        check(claude.cliEnvironment.isEmpty, "default account exports nothing")
        expect(WarmupRunner.environmentPrefix(for: claude), "", "default warm-up command is unchanged")
        expect(claude.loginCommand, "claude auth login", "default login command")
        expect(claude.logDirectoryURL, ToolID.claude.logDirectoryURL, "default logs stay in ~/.claude")

        expect(ProviderID.shellQuoted("a'b"), "'a'\\''b'", "embedded single quote is escaped")
    }

    static func testKeychainServiceNames() {
        expect(ProviderID.claudeKeychainServices(configDir: nil), ["Claude Code-credentials"], "default item name")
        let services = ProviderID.claudeKeychainServices(configDir: "/Users/test/.claude-work")
        expect(services.first, "Claude Code-credentials-03abf0ee", "Claude Code names a config dir's item by the first 8 hex of sha256")
        check(services.contains("Claude Code-credentials-03abf0ee6e606de9"), "16-hex variant is tolerated")
        check(!services.contains("Claude Code-credentials"), "an added account never reads the default item")
        let slashed = ProviderID.claudeKeychainServices(configDir: "/Users/test/.claude-work/")
        check(slashed.contains("Claude Code-credentials-03abf0ee"), "trailing slash also tries the trimmed path")
        expect(Set(services).count, services.count, "no duplicate service names")
    }

    static func testAccountValidation() {
        check(ProviderAccount.isValidHome("/Users/test/.claude-work"), "absolute path is valid")
        check(!ProviderAccount.isValidHome("~/.claude-work"), "unexpanded tilde is rejected")
        check(!ProviderAccount.isValidHome("relative/path"), "relative path is rejected")
        check(!ProviderAccount.isValidHome("/tmp/it's"), "single quote is rejected")
        check(!ProviderAccount.isValidHome("/tmp/a\nb"), "control characters are rejected")
        check(!ProviderAccount.isValidHome("/"), "root is rejected")

        check(ProviderAccount.isValidID("work-2"), "slug id is valid")
        check(!ProviderAccount.isValidID("default"), "the default id is reserved")
        check(!ProviderAccount.isValidID("a.b"), "dots would break key namespacing")
        check(!ProviderAccount.isValidID(""), "empty id is rejected")

        expect(ProviderAccount.slugified("İş Hesabı"), "is-hesabi", "Turkish names slugify to ASCII")
        expect(ProviderAccount.slugified("  Work!! Account  "), "work-account", "punctuation collapses")
        expect(ProviderAccount.slugified("!!!"), "", "nothing usable gives an empty slug")

        let home = ProviderAccount.suggestedHome(kind: .claude, name: "Work", existing: [], homeDirectory: "/Users/test")
        expect(home, "/Users/test/.claude-work", "suggested home")
        let second = ProviderAccount.suggestedHome(kind: .claude, name: "Work", existing: [home], homeDirectory: "/Users/test")
        expect(second, "/Users/test/.claude-work-2", "suggested home is unique")

        let defaults = UserDefaults(suiteName: "accounts-history-regression")!
        defaults.removePersistentDomain(forName: "accounts-history-regression")
        let accounts = [
            ProviderAccount(id: "work", kind: .claude, name: "Work", home: "/Users/test/.claude-work"),
            ProviderAccount(id: "bad.id", kind: .codex, name: "Bad", home: "/Users/test/.codex-bad"),
        ]
        ProviderAccount.save(accounts, to: defaults)
        let loaded = ProviderAccount.load(from: defaults)
        expect(loaded.map(\.id), ["work"], "invalid stored accounts are dropped on load")
        defaults.removePersistentDomain(forName: "accounts-history-regression")
    }

    // MARK: - History

    static func snapshot(
        at fetchedAt: Date,
        sessionUsed: Double?,
        weeklyUsed: Double?,
        resetAt: Date?,
        idle: Bool = false
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            tool: .claude,
            fetchedAt: fetchedAt,
            primarySource: "test",
            corroboratingSource: nil,
            fiveHour: sessionUsed.map {
                QuotaMetric(name: "5h", usedPercent: $0, remainingPercent: nil, resetAt: resetAt, detail: nil, isIdle: idle)
            },
            weekly: weeklyUsed.map {
                QuotaMetric(name: "weekly", usedPercent: $0, remainingPercent: nil, resetAt: nil, detail: nil)
            },
            extras: [],
            rawWindowKey: "k",
            message: nil
        )
    }

    static func testQuotaSample() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let active = QuotaSample(snapshot: snapshot(at: now, sessionUsed: 0.4234, weeklyUsed: 0.1, resetAt: now.addingTimeInterval(3600)))
        expect(active?.s, 0.423, "session used is stored as a rounded fraction")
        expect(active?.w, 0.1, "weekly used is stored")
        expect(active?.r, now.addingTimeInterval(3600), "an open window keeps its reset")

        let idle = QuotaSample(snapshot: snapshot(at: now, sessionUsed: 0, weeklyUsed: 0.2, resetAt: now.addingTimeInterval(5 * 3600), idle: true))
        check(idle?.r == nil, "an idle window's sliding projection is not stored as a reset")
        expect(idle?.s, 0, "an idle window reads 0% used")

        check(QuotaSample(snapshot: snapshot(at: now, sessionUsed: nil, weeklyUsed: nil, resetAt: nil)) == nil,
              "a snapshot with no windows is not recorded")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let sample = QuotaSample(t: now, s: 0.5, w: nil, r: nil)
        let roundTrip = (try? encoder.encode(sample)).flatMap { try? decoder.decode(QuotaSample.self, from: $0) }
        expect(roundTrip, sample, "samples round-trip through JSON")
    }

    static func testWindowGrouping() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let duration: TimeInterval = 5 * 3600
        let firstReset = base.addingTimeInterval(duration)
        let secondReset = firstReset.addingTimeInterval(duration + 1800)
        var samples: [QuotaSample] = []
        // Window 1, with a reset that drifts by seconds between polls (Codex).
        samples.append(QuotaSample(t: base.addingTimeInterval(60), s: 0.1, w: 0.01, r: firstReset))
        samples.append(QuotaSample(t: base.addingTimeInterval(3600), s: 0.6, w: 0.02, r: firstReset.addingTimeInterval(7)))
        samples.append(QuotaSample(t: base.addingTimeInterval(7200), s: 0.5, w: 0.02, r: firstReset.addingTimeInterval(-4)))
        // Idle gap: no reset.
        samples.append(QuotaSample(t: firstReset.addingTimeInterval(600), s: 0, w: 0.02, r: nil))
        // Stale reading after its own reset belongs to no window.
        samples.append(QuotaSample(t: firstReset.addingTimeInterval(120), s: 0.99, w: 0.02, r: firstReset))
        // Window 2 hits the limit.
        samples.append(QuotaSample(t: secondReset.addingTimeInterval(-duration + 60), s: 0.3, w: 0.05, r: secondReset))
        samples.append(QuotaSample(t: secondReset.addingTimeInterval(-60), s: 0.97, w: 0.09, r: secondReset))

        let windows = UsageHistory.windows(from: samples.shuffled(), duration: duration)
        expect(windows.count, 2, "drifting resets collapse into one window; idle and post-reset readings are ignored")
        expect(windows.first?.peakUsed, 0.6, "a window's peak is its highest reading")
        expect(windows.first?.samples, 3, "all three drifting readings count")
        expect(windows.first?.startAt, firstReset.addingTimeInterval(-duration), "window start = reset - duration")
        check(windows.last?.hitLimit == true, "97% used counts as hitting the limit")
        check(windows.first?.hitLimit == false, "60% used is not a limit hit")

        let stats = UsageHistory.stats(samples: samples, windows: windows)
        expect(stats.windowCount, 2, "stats count windows")
        expect(stats.limitHits, 1, "stats count limit hits")
        check(abs((stats.averagePeak ?? 0) - 0.785) < 0.0001, "average peak")
        expect(stats.latestWeekly, 0.09, "latest weekly comes from the newest sample")

        let empty = UsageHistory.stats(samples: [], windows: [])
        check(empty.averagePeak == nil && empty.latestWeekly == nil, "no data gives no averages")
    }

    static func testSampleSpacing() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = t0.addingTimeInterval(3600)
        let first = QuotaSample(t: t0, s: 0.2, w: nil, r: reset)
        check(UsageHistory.shouldRecord(first, after: nil), "the first sample is always kept")
        check(!UsageHistory.shouldRecord(QuotaSample(t: t0.addingTimeInterval(20), s: 0.21, w: nil, r: reset), after: first),
              "a burst re-poll of the same window is dropped")
        check(UsageHistory.shouldRecord(QuotaSample(t: t0.addingTimeInterval(61), s: 0.21, w: nil, r: reset), after: first),
              "a regular poll is kept")
        check(UsageHistory.shouldRecord(QuotaSample(t: t0.addingTimeInterval(20), s: 0, w: nil, r: reset.addingTimeInterval(5 * 3600)), after: first),
              "a burst reading that opens a new window is kept")
        let idle = QuotaSample(t: t0, s: 0, w: nil, r: nil)
        check(UsageHistory.shouldRecord(QuotaSample(t: t0.addingTimeInterval(20), s: 0.01, w: nil, r: reset), after: idle),
              "the claim right after an idle reading is kept")
    }

    static func testChartSegments() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = [
            QuotaSample(t: t0, s: 0.1, w: 0.5, r: nil),
            QuotaSample(t: t0.addingTimeInterval(300), s: nil, w: 0.5, r: nil),
            QuotaSample(t: t0.addingTimeInterval(600), s: 0.2, w: 0.5, r: nil),
            QuotaSample(t: t0.addingTimeInterval(4 * 3600), s: 0.3, w: 0.6, r: nil),
        ]
        let session = UsageHistory.chartPoints(samples.reversed()) { $0.s }
        expect(session.map(\.value), [0.1, 0.2, 0.3], "nil values are skipped, order is by time")
        expect(session.map(\.segment), [0, 0, 1], "a gap longer than 45 min starts a new segment")
        expect(Set(session.map(\.id)).count, session.count, "point ids are unique")
    }

    static func testHistoryStore() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qw-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let old = QuotaSample(t: now.addingTimeInterval(-UsageHistory.retention - 3600), s: 0.1, w: nil, r: nil)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        var seed = Data()
        seed.append(try! encoder.encode(old)); seed.append(0x0A)
        seed.append(Data("not json\n".utf8))
        try? seed.write(to: dir.appendingPathComponent("claude.jsonl"))

        let store = UsageHistoryStore(directory: dir)
        store.record(QuotaSample(t: now.addingTimeInterval(-600), s: 0.2, w: 0.1, r: nil), storageKey: "claude")
        store.record(QuotaSample(t: now.addingTimeInterval(-590), s: 0.25, w: 0.1, r: nil), storageKey: "claude")
        store.record(QuotaSample(t: now.addingTimeInterval(-300), s: 0.3, w: 0.1, r: nil), storageKey: "claude")
        store.record(QuotaSample(t: now.addingTimeInterval(-300), s: 0.9, w: 0.1, r: nil), storageKey: "claude.work")

        let samples = syncSamples(store, key: "claude", since: .distantPast)
        expect(samples.map(\.s), [0.2, 0.3], "expired and corrupt lines are pruned; bursts are dropped")
        let work = syncSamples(store, key: "claude.work", since: .distantPast)
        expect(work.map(\.s), [0.9], "accounts have separate files")

        let reopened = UsageHistoryStore(directory: dir)
        expect(syncSamples(reopened, key: "claude", since: .distantPast).map(\.s), [0.2, 0.3], "samples persist across launches")
        expect(syncSamples(reopened, key: "claude", since: now.addingTimeInterval(-400)).map(\.s), [0.3], "range filter")

        let text = (try? String(contentsOf: dir.appendingPathComponent("claude.jsonl"), encoding: .utf8)) ?? ""
        expect(text.split(separator: "\n").count, 2, "the pruned file was rewritten without stale lines")
    }

    static func syncSamples(_ store: UsageHistoryStore, key: String, since: Date) -> [QuotaSample] {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: [QuotaSample] = []
        Task.detached {
            result = await store.samples(storageKey: key, since: since)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    static func testDailyAndHourlyTokens() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let provider = LocalUsageProvider(calendar: utc)
        provider.hourCalendar = utc
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qw-daily-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("p")
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let lines = [
            // Monday 2026-06-15 10:xx UTC, twice in one hour.
            #"{"timestamp":"2026-06-15T10:05:00Z","message":{"id":"a","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}"#,
            #"{"timestamp":"2026-06-15T10:55:00Z","message":{"id":"b","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}"#,
            // Saturday 2026-06-13 23:xx UTC.
            #"{"timestamp":"2026-06-13T23:30:00Z","message":{"id":"c","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":7,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}"#,
        ]
        try? (lines.joined(separator: "\n") + "\n").write(to: project.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)

        let now = ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z")!
        let summary = provider.usage(for: .claude, baseURL: root, now: now)
        expect(summary.hourly.reduce(0) { $0 + $1.tokens }, summary.last30Days.totalTokens, "hours add up to the 30-day total")
        check(summary.hourly.allSatisfy { ($0.costUSD ?? 0) > 0 }, "priced hours carry a cost")
        check(abs(summary.hourly.compactMap(\.costUSD).reduce(0, +) - (summary.last30Days.costUSD ?? -1)) < 0.000001,
              "hourly costs add up to the 30-day cost")
        let monday10 = utc.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 10))!
        let saturday23 = utc.date(from: DateComponents(year: 2026, month: 6, day: 13, hour: 23))!
        expect(summary.hourly.map(\.hour), [saturday23, monday10], "tokens are bucketed per clock hour, oldest first, empty hours omitted")
        expect(summary.hourly.map(\.tokens), [7, 150], "per-hour token totals")

        let week = UsageHistory.hourOfWeek(summary.hourly, since: .distantPast, calendar: utc)
        expect(week.count, 168, "a full week of hours")
        expect(week[(2 - 1) * 24 + 10], 150, "Monday 10:00 cell")
        expect(week[(7 - 1) * 24 + 23], 7, "Saturday 23:00 cell")
        expect(UsageHistory.hourOfWeek(summary.hourly, since: monday10, calendar: utc).reduce(0, +), 150,
               "the 30-day view drops hours before its start")

        let rows = UsageHistory.dayRows(summary.hourly, days: 7, now: now, calendar: utc)
        expect(rows.count, 7, "7d shows seven real days")
        expect(rows.last?.day, utc.startOfDay(for: now), "today is the last row")
        expect(rows.last?.cells[10], 150, "today's 10:00")
        check(rows.last?.cells[12] == 0 && rows.last?.cells[13] == nil, "the current hour counts, later hours are not yet")
        expect(rows[rows.count - 3].cells[23], 7, "Saturday is two rows above today")
        check(rows.first?.cells.allSatisfy { $0 == 0 } == true, "a past day has all 24 hours")

        let recent = UsageHistory.recentHours(summary.hourly, count: 24, now: now, calendar: utc)
        expect(recent.count, 24, "24h shows 24 hours")
        expect(recent.last?.hour, utc.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12)), "the newest hour is now")
        expect(recent.first?.hour, utc.date(from: DateComponents(year: 2026, month: 6, day: 14, hour: 13)), "the oldest is 23 hours back")
        expect(recent.map(\.tokens).reduce(0, +), 150, "the 24h strip only holds the last 24 hours")

        let merged = UsageHistory.mergeHourly([summary.hourly, [TokenUsageHour(hour: monday10, tokens: 5)]])
        expect(merged.map(\.tokens), [7, 155], "accounts add up per hour in All")

        let days = UsageHistory.dayTotals(summary.hourly, days: 7, now: now, calendar: utc)
        expect(days.count, 7, "7 local days")
        expect(days.last?.hour, utc.startOfDay(for: now), "today is the last day")
        expect(days.map(\.tokens), [0, 0, 0, 0, 7, 0, 150], "each hour lands on its local day")
        check(days.first?.costUSD == 0, "an empty day costs nothing")

        // In UTC+3 the Saturday 23:30 UTC record is Sunday 02:00 local.
        var istanbul = utc
        istanbul.timeZone = TimeZone(secondsFromGMT: 3 * 3600)!
        let localProvider = LocalUsageProvider(calendar: utc)
        localProvider.hourCalendar = istanbul
        let local = localProvider.usage(for: .claude, baseURL: root, now: now)
        let localDays = UsageHistory.dayTotals(local.hourly, days: 7, now: now, calendar: istanbul)
        expect(localDays.map(\.tokens), [0, 0, 0, 0, 0, 7, 150], "days follow local time, not UTC")

        let unpriced = UsageHistory.mergeHourly([[TokenUsageHour(hour: monday10, tokens: 5, costUSD: nil)], summary.hourly])
        check(unpriced.last?.costUSD == nil, "an unpriced share makes the hour's cost unknown")
        check(UsageHistory.total(unpriced, at: now).costUSD == nil, "and the range total unknown")
        check(UsageHistory.total([TokenUsageHour(hour: monday10, tokens: 0, costUSD: nil)], at: now).costUSD == 0,
              "an empty unpriced bucket doesn't poison the total")

        let missing = LocalUsageProvider(calendar: utc).usage(for: .claude, baseURL: root.appendingPathComponent("nope"), now: now)
        check(missing.hourly.isEmpty, "and no hourly usage")
    }

    // MARK: - Harness

    static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { failures.append(message) }
    }

    static func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        checks += 1
        if actual != expected { failures.append("\(message): expected \(expected), got \(actual)") }
    }
}
