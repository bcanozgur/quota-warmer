import Foundation
@testable import QuotaWarmerCore

/// Regression suite for multi-account identity (`Models/ProviderAccount.swift`)
/// and quota history (`Models/UsageHistory.swift`, the daily/hourly token data
/// from `LocalUsageProvider`) and the `status.json` export
/// (`Models/QuotaStatus.swift`). Compiled standalone like the other regression
/// scripts (see .github/workflows/ci.yml).
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
        testAppSettings()
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
        testStatusExport()
        await testEventLog()
        testImpactReport()
        testDiagnosticRotation()

        if failures.isEmpty {
            print("Accounts & history regressions passed (\(checks) checks)")
        } else {
            for failure in failures { print("FAIL: \(failure)") }
            print("\(failures.count) of \(checks) accounts/history checks failed")
            exit(1)
        }
    }

    // MARK: - Settings

    /// Key strings are the on-disk format of existing installs; this pins them
    /// and every default so a refactor cannot silently rename or re-default one.
    static func testAppSettings() {
        typealias K = AppSettings.Key
        let pinned: [(String, String)] = [
            (K.schemaVersion, "settingsSchemaVersion"),
            (K.refreshInterval, "refreshInterval"), (K.windowDurationSecs, "windowDurationSecs"),
            (K.rateLimitGuard, "rateLimitGuard"), (K.globalPassive, "globalPassive"),
            (K.morningPrewarmEnabled, "morningPrewarmEnabled"), (K.morningPrewarmHour, "morningPrewarmHour"),
            (K.morningPrewarmMinute, "morningPrewarmMinute"), (K.morningPrewarmWeekdaysOnly, "morningPrewarmWeekdaysOnly"),
            (K.lastMorningWarmDayLegacy, "lastMorningWarmDay"),
            (K.notifyWarning, "notifyWarning"), (K.notifyActivated, "notifyActivated"),
            (K.alertSessionEnabled, "alertSessionEnabled"), (K.alertSessionFirst, "alertSessionFirst"),
            (K.alertSessionSecond, "alertSessionSecond"), (K.alertWeeklyEnabled, "alertWeeklyEnabled"),
            (K.alertWeeklyFirst, "alertWeeklyFirst"), (K.alertWeeklySecond, "alertWeeklySecond"),
            (K.alertPaceEnabled, "alertPaceEnabled"),
            (K.colorfulQuotaBars, "colorfulQuotaBars"), (K.appearanceMode, "appearanceMode"),
            (K.historyRange, "historyRange"), (K.historyProvider, "historyProvider"),
            (K.globalHotKeyEnabled, "globalHotKeyEnabled"), (K.globalHotKeyCode, "globalHotKeyCode"),
            (K.globalHotKeyModifiers, "globalHotKeyModifiers"),
            (K.onboardingCompletedVersion, "onboardingCompletedVersion"), (K.onboardingDismissed, "onboardingDismissed"),
            (K.launchAtLogin, "launchAtLogin"), (K.debugLevel, "debugLevel"), (K.accounts, "accounts.v1"),
            (K.toolMode("claude.work"), "toolMode.claude.work"),
            (K.toolActiveLegacy("codex"), "toolActive.codex"),
            (K.menuBarVisible("codex"), "menuBarVisible.codex"),
            (K.quotaDisplayMode("codex"), "quotaDisplayMode.codex"),
            (K.quotaAlertMarks("codex"), "quotaAlertMarks.codex"),
            (K.lastAutoWindowKey("claude"), "lastAutoWindowKey.claude"),
            (K.lastAutoWarmEndsAt("claude"), "lastAutoWarmEndsAt.claude"),
            (K.confirmedWarmupResetAt("claude"), "confirmedWarmupResetAt.claude"),
            (K.lastMorningWarmDay("claude"), "lastMorningWarmDay.claude"),
        ]
        for (actual, expected) in pinned { expect(actual, expected, "settings key \(expected)") }

        let suite = "accounts-history-regression-settings"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = AppSettings(defaults: defaults)
        expect(settings.refreshInterval, 300, "default refresh interval")
        expect(settings.windowDuration, 5 * 3600, "default window duration")
        expect(settings.rateLimitGuard, true, "default rate-limit guard on")
        expect(settings.globalPassive, false, "default not paused")
        expect(settings.morningPrewarmEnabled, false, "default morning pre-warm off")
        expect(settings.morningHour, 6, "default morning hour")
        expect(settings.morningMinute, 0, "default morning minute")
        expect(settings.morningWeekdaysOnly, true, "default weekdays only")
        expect(settings.onboardingCompletedVersion, nil, "default onboarding version unset")
        expect(settings.onboardingDismissed, false, "default banner not dismissed")
        expect(settings.lastMorningWarmDay("claude"), nil, "default no morning day")

        defaults.set(0, forKey: "refreshInterval")
        expect(settings.refreshInterval, 300, "a stored 0 refresh interval falls back to 300")
        defaults.set(120, forKey: "refreshInterval")
        expect(settings.refreshInterval, 120, "stored refresh interval wins")
        defaults.set(-5, forKey: "windowDurationSecs")
        expect(settings.windowDuration, 5 * 3600, "non-positive window duration falls back")
        defaults.set(3600, forKey: "windowDurationSecs")
        expect(settings.windowDuration, 3600, "stored window duration wins")

        settings.globalPassive = true
        expect(defaults.bool(forKey: "globalPassive"), true, "globalPassive writes its key")
        settings.setLastMorningWarmDay("2026-1-2", for: "claude")
        expect(defaults.string(forKey: "lastMorningWarmDay.claude"), "2026-1-2", "morning day writes per-tool key")

        expect(settings.schemaVersion, 0, "fresh defaults have no schema version")
        settings.migrateIfNeeded()
        expect(settings.schemaVersion, AppSettings.currentSchemaVersion, "migration stamps the schema version")
        expect(defaults.integer(forKey: "refreshInterval"), 120, "migration leaves values untouched")
        settings = AppSettings(defaults: defaults)
        settings.migrateIfNeeded()
        expect(settings.schemaVersion, AppSettings.currentSchemaVersion, "migration is idempotent")
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

        // Relaunch with an expired Claude token: the newest sample is the only
        // reading, and it must still tell whether its window ended.
        let restored = active?.lastKnownSnapshot(tool: .claude)
        expect(restored?.fiveHour?.remainingFraction, 0.577, "last known: session remaining is restored")
        expect(restored?.weekly?.usedPercent, 0.1, "last known: weekly used is restored")
        expect(restored?.fetchedAt, now, "last known: keeps the sample's time, so it is never fresh")
        check(restored?.freshness(now: now.addingTimeInterval(3600)) == .expired, "last known: an old sample reads expired")
        check(restored?.lastKnownWindowEnded(now: now.addingTimeInterval(1800)) == false, "last known: a future reset is a running window")
        check(restored?.lastKnownWindowEnded(now: now.addingTimeInterval(3600)) == true, "last known: a passed reset is an ended window")
        let restoredIdle = idle?.lastKnownSnapshot(tool: .claude)
        check(restoredIdle?.fiveHour?.isIdle == true, "last known: a sample without a reset was idle")
        check(restoredIdle?.lastKnownWindowEnded(now: now) == true, "last known: an idle reading has no running window")
        let weeklyOnly = QuotaSample(t: now, s: nil, w: 0.3, r: nil).lastKnownSnapshot(tool: .claude)
        check(weeklyOnly?.fiveHour == nil, "last known: an unsettled rollover sample restores no 5h window")
        check(weeklyOnly?.lastKnownWindowEnded(now: now) == false, "last known: no 5h window never counts as ended")
        check(QuotaSample(t: now, s: nil, w: nil, r: nil).lastKnownSnapshot(tool: .claude) == nil, "last known: an empty sample restores nothing")

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

        let h: TimeInterval = 3600
        let weekly = UsageHistory.chartPoints([
            QuotaSample(t: t0, s: nil, w: 0.2, r: nil),
            QuotaSample(t: t0.addingTimeInterval(8 * h), s: nil, w: 0.3, r: nil),    // overnight gap
            QuotaSample(t: t0.addingTimeInterval(30 * h), s: nil, w: 0.4, r: nil),   // too long to bridge
            QuotaSample(t: t0.addingTimeInterval(32 * h), s: nil, w: 0.05, r: nil),  // reset inside the gap
        ]) { $0.w }
        let bridges = UsageHistory.bridges(weekly)
        expect(bridges.map(\.from.value), [0.2], "only a short, non-dropping gap is bridged")
        expect(bridges.map(\.to.value), [0.3], "the bridge ends at the next segment's first point")
        expect(UsageHistory.joiningBridges(weekly).map(\.segment), [0, 0, 1, 2], "a bridged gap shares one fill; the rest stay apart")
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

        let fiveHours: TimeInterval = 5 * 3600
        let peakWindows = [
            QuotaWindowSummary(resetAt: utc.startOfDay(for: now).addingTimeInterval(-86400 + 9 * 3600), duration: fiveHours, peakUsed: 0.4, samples: 3),
            QuotaWindowSummary(resetAt: utc.startOfDay(for: now).addingTimeInterval(-86400 + 20 * 3600), duration: fiveHours, peakUsed: 0.9, samples: 3),
            // Opens 22:00 the day before yesterday, resets after midnight: counts for the day it opened.
            QuotaWindowSummary(resetAt: utc.startOfDay(for: now).addingTimeInterval(-86400 + 3 * 3600), duration: fiveHours, peakUsed: 0.2, samples: 2),
        ]
        let peaks = UsageHistory.dailyPeaks(peakWindows, days: 3, now: now, calendar: utc)
        expect(peaks.map(\.day), (0..<3).reversed().map { utc.date(byAdding: .day, value: -$0, to: utc.startOfDay(for: now))! }, "3 local days, today last")
        expect(peaks.map(\.peak), [0.2, 0.9, nil], "each day keeps its fullest window, by the day it opened")
        expect(peaks.map(\.windows), [1, 2, 0], "and counts the windows that opened")

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

    // MARK: - Status export

    static func testStatusExport() {
        let now = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15T08:00:00Z
        let work = ProviderID(kind: .claude, accountID: "work", home: "/tmp/.claude-work", name: "Work")
        let file = QuotaStatusExport.make([
            QuotaStatusExport.Entry(
                provider: .default(.claude), mode: .autoWarm, displayMode: .remaining, pinned: true,
                snapshot: snapshot(at: now.addingTimeInterval(-60), sessionUsed: 0.42, weeklyUsed: 0.105,
                                   resetAt: now.addingTimeInterval(2 * 3600 + 13 * 60))
            ),
            QuotaStatusExport.Entry(provider: work, mode: .monitor, displayMode: .used, pinned: false, snapshot: nil),
            QuotaStatusExport.Entry(
                provider: .default(.codex), mode: .off, displayMode: .remaining, pinned: false,
                snapshot: snapshot(at: now.addingTimeInterval(-10 * 60), sessionUsed: 0, weeklyUsed: nil,
                                   resetAt: now.addingTimeInterval(5 * 3600), idle: true)
            ),
        ], now: now)

        let expected = """
        {
          "generatedAt" : "2027-01-15T08:00:00Z",
          "providers" : [
            {
              "account" : "default",
              "displayMode" : "remaining",
              "fetchedAt" : "2027-01-15T07:59:00Z",
              "freshness" : "fresh",
              "id" : "claude",
              "mode" : "autoWarm",
              "name" : "Claude",
              "pinned" : true,
              "session" : {
                "idle" : false,
                "remainingPercent" : 58,
                "resetAt" : "2027-01-15T10:13:00Z",
                "settling" : false,
                "usedPercent" : 42
              },
              "tool" : "claude",
              "weekly" : {
                "idle" : false,
                "remainingPercent" : 89,
                "settling" : false,
                "usedPercent" : 11
              }
            },
            {
              "account" : "work",
              "displayMode" : "used",
              "freshness" : "unknown",
              "id" : "claude.work",
              "mode" : "monitor",
              "name" : "Claude · Work",
              "pinned" : false,
              "tool" : "claude"
            },
            {
              "account" : "default",
              "displayMode" : "remaining",
              "fetchedAt" : "2027-01-15T07:50:00Z",
              "freshness" : "stale",
              "id" : "codex",
              "mode" : "off",
              "name" : "Codex",
              "pinned" : false,
              "session" : {
                "idle" : true,
                "remainingPercent" : 100,
                "resetAt" : "2027-01-15T13:00:00Z",
                "settling" : false,
                "usedPercent" : 0
              },
              "tool" : "codex"
            }
          ],
          "schemaVersion" : 1
        }

        """
        let data = try? QuotaStatusExport.encode(file)
        expect(data.flatMap { String(data: $0, encoding: .utf8) }, expected, "status.json encodes the documented schema")
        expect(data.flatMap { try? QuotaStatusExport.decode($0) }, file, "status.json round-trips")

        let settling = QuotaStatusExport.provider(QuotaStatusExport.Entry(
            provider: .default(.claude), mode: .monitor, displayMode: .remaining, pinned: true,
            snapshot: snapshot(at: now, sessionUsed: 0.9, weeklyUsed: nil, resetAt: now.addingTimeInterval(5 * 3600 - 60))
        ), now: now)
        expect(settling.session?.settling, true, "a just-rolled-over reading is marked settling")
        expect(settling.session?.usedPercent, 90, "and still carries the reported percent")
    }

    // MARK: - Event log

    static func testEventLog() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let acct = ProviderID(kind: .claude, accountID: "work")
        let event = HistoryEvent(
            timestamp: now, tool: acct, kind: .resetDetected, title: "Window claim confirmed", detail: "d",
            outcome: .confirmed, windowKey: "k1", windowResetAt: now.addingTimeInterval(3600), model: "m"
        )
        let line = try? JSONEncoder().encode(event)
        let back = line.flatMap { try? JSONDecoder().decode(HistoryEvent.self, from: $0) }
        expect(back?.id, event.id, "event keeps its stable id")
        expect(back?.tool?.storageKey, "claude.work", "event provider round-trips by storageKey")
        expect(back?.outcome, .confirmed, "event outcome round-trips")
        expect(back?.windowKey, "k1", "event window key round-trips")
        expect(back?.windowResetAt, now.addingTimeInterval(3600), "event reset time round-trips")
        expect(back?.model, "m", "event model round-trips")
        let plain = HistoryEvent(timestamp: now, tool: nil, kind: .updateCheck, title: "t", detail: "d")
        let plainBack = (try? JSONEncoder().encode(plain)).flatMap { try? JSONDecoder().decode(HistoryEvent.self, from: $0) }
        check(plainBack != nil && plainBack?.tool == nil && plainBack?.outcome == nil, "unstructured event round-trips with nil fields")
        expect(ProviderID.fromStorageKey("codex")?.isDefault, true, "default storage key parses")
        check(ProviderID.fromStorageKey("bogus.x") == nil, "unknown tool key is rejected")

        // Retention and cap.
        let old = HistoryEvent(timestamp: now.addingTimeInterval(-91 * 86400), tool: nil, kind: .quotaFetch, title: "old", detail: "")
        let recent = HistoryEvent(timestamp: now.addingTimeInterval(-89 * 86400), tool: nil, kind: .quotaFetch, title: "recent", detail: "")
        expect(EventLogStore.prune([recent, old], now: now).map(\.title), ["recent"], "events older than 90 days are pruned")
        let many = (0..<12).map { HistoryEvent(timestamp: now.addingTimeInterval(Double($0)), tool: nil, kind: .quotaFetch, title: "e\($0)", detail: "") }
        let capped = EventLogStore.prune(many.reversed(), now: now, maxLines: 5)
        expect(capped.map(\.title), ["e7", "e8", "e9", "e10", "e11"], "cap keeps the newest lines, oldest-first")

        // Corrupt-line tolerance and file round-trip.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qw-eventlog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = EventLogStore(directory: dir)
        let good = String(data: line ?? Data(), encoding: .utf8) ?? ""
        let oldLine = String(data: (try? JSONEncoder().encode(old)) ?? Data(), encoding: .utf8) ?? ""
        try? "\(good)\nnot json\n{\"id\":\"x\"}\n\(oldLine)\n".write(to: store.fileURL, atomically: true, encoding: .utf8)
        let loaded = await store.loadAndPrune(now: now)
        expect(loaded.count, 1, "corrupt and expired lines are skipped on load")
        let rewritten = (try? String(contentsOf: store.fileURL, encoding: .utf8)) ?? ""
        expect(rewritten.split(separator: "\n").count, 1, "the file is rewritten without the bad lines")

        let other = HistoryEvent(timestamp: now, tool: .default(.codex), kind: .quotaFetch, title: "o", detail: "")
        store.append(other)
        await store.flush()
        expect(await store.loadAndPrune(now: now).count, 2, "appended events persist")
        store.removeAll(for: acct)
        await store.flush()
        expect(await store.loadAndPrune(now: now).map(\.title), ["o"], "removing an account drops only its events")
        expect(await store.recent(limit: 1).count, 1, "recent honours its limit")

        let filter = EventFilter(providerKey: "claude.work", group: .warmups)
        check(filter.matches(event) && !filter.matches(other), "filter matches provider and kind group")
    }

    static func testDiagnosticRotation() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qw-diag-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for round in 1...4 {
            try? "gen\(round)".write(to: dir.appendingPathComponent("diagnostics.log"), atomically: true, encoding: .utf8)
            DiagnosticLogger.rotate(in: dir, maxFiles: 3)
        }
        // After rotation the live file is gone; the three newest generations are .1, .2 only (live is rewritten later).
        let names = DiagnosticLogger.logFiles(in: dir, maxFiles: 3).map(\.lastPathComponent)
        expect(names, ["diagnostics.1.log", "diagnostics.2.log"], "rotation keeps a bounded set of files")
        expect(try? String(contentsOf: dir.appendingPathComponent("diagnostics.1.log"), encoding: .utf8), "gen4", "newest rotated file is .1")
        expect(DiagnosticLogger.redacted("Authorization: Bearer abcdefghijklmnop1234").contains("abcdefghij"), false, "redaction strips bearer tokens")
    }

    // MARK: - Impact report

    static func testImpactReport() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)   // on the hour
        let day: TimeInterval = 86_400
        let hour: TimeInterval = 3_600
        let claude = ProviderID.default(.claude)
        let fake = ModelCatalog.Model(id: "m", name: nil, aliases: nil, match: nil,
                                      input: 1, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 5)
        let price: (ToolID, String?) -> ModelCatalog.Model? = { _, model in model == "haiku" ? fake : nil }

        func sent(_ t: Date, _ source: WarmupSource?, model: String = "haiku") -> HistoryEvent {
            HistoryEvent(timestamp: t, tool: claude, kind: source == .manual ? .manualWarmup : .autoWarmup,
                         title: "sent", detail: "", outcome: .sent, model: model, source: source)
        }
        func confirmed(_ t: Date, key: String, start: Date, source: WarmupSource? = nil) -> HistoryEvent {
            HistoryEvent(timestamp: t, tool: claude, kind: .resetDetected, title: "confirmed", detail: "",
                         outcome: .confirmed, windowKey: key, windowResetAt: start.addingTimeInterval(5 * hour),
                         source: source)
        }
        func outcome(_ t: Date, _ o: EventOutcome) -> HistoryEvent {
            HistoryEvent(timestamp: t, tool: claude, kind: .pollingError, title: "x", detail: "", outcome: o)
        }

        let a = now - 3 * day, b = now - 2 * day, c = now - day, d = now - 10 * day, e = now - 5 * day
        var events: [HistoryEvent] = []
        // A: auto, user starts working 2h in (a noise-sized warm-up bucket precedes it).
        events += [sent(a + 60, .auto), confirmed(a + 120, key: "kA", start: a + 60)]
        // B: morning claim, never used. The confirmation carries no source: traced via its warm-up.
        events += [sent(b + 60, .morning), confirmed(b + 120, key: "kB", start: b + 60)]
        // C: manual claim, used immediately.
        events += [sent(c + 60, .manual), confirmed(c + 120, key: "kC", start: c + 60)]
        // E: first reported missed, then healed into a confirmation, plus a duplicate receipt.
        events += [sent(e + 60, .auto), outcome(e + 100, .missed), confirmed(e + 200, key: "kE", start: e + 60),
                   confirmed(e + 260, key: "kE", start: e + 60)]
        // D: only in the 30d range.
        events += [sent(d + 60, .auto), confirmed(d + 120, key: "kD", start: d + 60)]
        // F: a genuine miss with an unpriced model, and a failed command.
        events += [sent(now - 4 * hour, .auto, model: "mystery"), outcome(now - 4 * hour + 200, .missed),
                   outcome(now - 6 * hour, .failed)]
        // Skips are not warm-ups.
        events.append(HistoryEvent(timestamp: now - hour, tool: claude, kind: .autoWarmup, title: "skip", detail: "",
                                   outcome: .skipped, source: .auto))

        let hourly = [
            TokenUsageHour(hour: a, tokens: 5_000),                 // the warm-up itself
            TokenUsageHour(hour: a + 2 * hour, tokens: 1_000),      // first real use
            TokenUsageHour(hour: c, tokens: 500_000),               // immediate use
        ]
        let samples: [QuotaSample] = [
            QuotaSample(t: now - 3 * day, s: 0.5, w: 0.97, r: now - 3 * day + hour),
            QuotaSample(t: now - 3 * day + 600, s: 0.9, w: 0.97, r: now - 3 * day + hour),
            QuotaSample(t: now - 2 * day, s: 0.5, w: 0.4, r: now - 2 * day + hour),
            QuotaSample(t: now - 12 * day, s: 0.2, w: 0.4, r: now - 12 * day + hour),
        ]
        let input = ImpactInput(provider: claude, events: events, samples: samples, hourly: hourly, windowDuration: 5 * hour)

        let week = ImpactReport.make(inputs: [input], range: .week, now: now, calendar: cal, price: price)
        expect(week.claims.claimed, 4, "7d: four distinct windows claimed (duplicate receipt counted once)")
        expect(week.claims.auto, 2, "7d: auto claims include the one traced through its warm-up")
        expect(week.claims.morning, 1, "7d: morning claim traced from its warm-up")
        expect(week.claims.manual, 1, "7d: manual claim")
        expect(week.claims.missed, 1, "7d: a miss later healed is not a miss")
        expect(week.claims.failed, 1, "7d: failed command counted")
        check(abs((week.claims.successRate ?? 0) - 4.0 / 6.0) < 0.0001, "7d: success rate = claimed / resolved")
        expect(week.headStart.measuredWindows, 2, "7d: head start measured for the two windows with usage")
        expect(week.headStart.unusedWindows, 2, "7d: claimed-but-unused windows (B, E) are reported, not averaged")
        expect(week.headStart.total, 2 * hour - 60, "7d: head start = window start to first real use; warm-up bucket ignored")
        check(abs((week.headStart.average ?? 0) - (2 * hour - 60) / 2) < 0.001, "7d: average head start")
        expect(week.cost.warmups, 5, "7d: skips are not warm-ups")
        expect(week.cost.pricedWarmups, 4, "7d: unpriced model not counted as priced")
        check(abs(week.cost.usd - 4 * 0.0155) < 1e-9, "7d: estimated cost = tokens x catalog price")
        expect(week.cost.displayText, "$0.06+", "7d: partial cost shows a floor")
        expect(week.utilization.windows, 2, "7d: windows observed")
        expect(week.utilization.highUseWindows, 1, "7d: one window reached 80%")
        expect(week.buckets.count, 7, "7d chart has one bucket per day")
        expect(week.buckets.reduce(0) { $0 + $1.total }, 4, "7d chart buckets sum to claimed")
        expect(week.isEmpty, false, "report with claims is not empty")

        let month = ImpactReport.make(inputs: [input], range: .month, now: now, calendar: cal, price: price)
        expect(month.claims.claimed, 5, "30d includes the older claim")
        expect(month.utilization.windows, 3, "30d windows")
        expect(month.utilization.weeks >= 2, true, "30d weeks observed")
        expect(month.utilization.weeksAtLimit, 1, "one week hit the weekly limit")
        expect(month.buckets.count, 30, "30d chart has one bucket per day")

        let all = ImpactReport.make(inputs: [input], range: .all, now: now, calendar: cal, price: price)
        expect(all.claims.claimed, 5, "all-time claims")

        // A window that starts before the first bucket and ends before usage: nothing measured.
        let late = ImpactInput(
            provider: claude,
            events: [sent(d + 60, .auto), confirmed(d + 120, key: "kD", start: d + 60)],
            samples: [], hourly: [TokenUsageHour(hour: d + 8 * hour, tokens: 9_000)], windowDuration: 5 * hour)
        let lateReport = ImpactReport.make(inputs: [late], range: .all, now: now, calendar: cal, price: price)
        expect(lateReport.headStart.measuredWindows, 0, "usage after the window ended is not a head start")
        check(lateReport.headStart.average == nil, "no average without measured windows")
        let started = d + 60
        expect(ImpactReport.firstUsage(in: [TokenUsageHour(hour: d, tokens: 100_000)],
                                       from: started, to: started + 5 * hour, warmupAt: started, calendar: cal),
               started, "usage in the hour the window opened counts from the window start (zero head start)")

        // Unpriced model never reads as $0.00.
        let unpriced = ImpactReport.make(
            inputs: [ImpactInput(provider: claude, events: [sent(a, .auto, model: "mystery")], samples: [], hourly: [], windowDuration: 5 * hour)],
            range: .week, now: now, calendar: cal, price: price)
        expect(unpriced.cost.displayText, "unpriced", "unpriced model is labelled, not $0.00")
        expect(week.cost.warmups > 0 && ImpactCost().displayText == "–", true, "no warm-ups shows a dash")

        // Another account's events are not mixed in.
        let other = ImpactInput(provider: ProviderID(kind: .claude, accountID: "work"), events: events, samples: [], hourly: [], windowDuration: 5 * hour)
        expect(ImpactReport.make(inputs: [other], range: .all, now: now, calendar: cal, price: price).claims.attempts, 0,
               "events of other accounts are ignored")

        // Empty / sparse data.
        let none = ImpactReport.make(inputs: [], range: .month, now: now, calendar: cal, price: price)
        check(none.isEmpty && none.claims.successRate == nil && none.utilization.highUseShare == nil, "no data is empty, with no rates")
        let bare = ImpactReport.make(inputs: [ImpactInput(provider: claude, events: [], samples: [], hourly: [], windowDuration: 5 * hour)],
                                     range: .all, now: now, calendar: cal, price: price)
        check(bare.isEmpty && bare.buckets.isEmpty, "empty account is empty")

        // Event lines.
        let oldLine = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","t":1799990000,"provider":"claude","kind":"autoWarmup","title":"Auto warmup sent","detail":"Command completed","outcome":"sent"}"#
        let old = try? JSONDecoder().decode(HistoryEvent.self, from: Data(oldLine.utf8))
        check(old != nil && old?.source == nil && old?.outcome == .sent, "event lines written before `source` still decode")
        let weird = oldLine.dropLast() + #","source":"from-the-future"}"#
        check((try? JSONDecoder().decode(HistoryEvent.self, from: Data(weird.utf8))) != nil, "an unknown source value does not drop the event")
        let roundTrip = (try? JSONEncoder().encode(sent(now, .morning))).flatMap { try? JSONDecoder().decode(HistoryEvent.self, from: $0) }
        expect(roundTrip?.source, .morning, "source round-trips")
        expect(WarmupSource(mode: "scheduled-catchup"), .morning, "catch-up warm-up is a morning warm-up")
        expect(WarmupSource(mode: "auto"), .auto, "auto mode")
        expect(WarmupSource(mode: "manual"), .manual, "manual mode")
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
