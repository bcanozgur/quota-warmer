import Foundation

/// Typed access to every `UserDefaults` setting QuotaWarmer persists. Key
/// strings are part of the on-disk format (existing installs, `@AppStorage`
/// in the Settings views, the Keychain-free account cleanup in `removeAccount`)
/// and must never change; `scripts/accounts-history-regression.swift` pins them.
///
/// Self-contained on purpose: it is compiled into the regression suites
/// (`QuotaWarmerCore` in Package.swift), so it must not depend on app-only code.
///
/// `@unchecked Sendable`: the only stored property is a `UserDefaults`, which
/// is documented as thread-safe.
struct AppSettings: @unchecked Sendable {
    /// Bump when a stored value needs rewriting; `migrateIfNeeded()` runs the
    /// steps between the stored version and this one.
    static let currentSchemaVersion = 1

    static let shared = AppSettings()

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Keys

    /// Every key string. Per-provider keys are builders taking the provider's
    /// `rawValue`/`storageKey` (identical strings: see `ProviderID`).
    enum Key {
        static let schemaVersion = "settingsSchemaVersion"

        // Polling & scheduling
        static let refreshInterval = "refreshInterval"
        static let windowDurationSecs = "windowDurationSecs"
        static let rateLimitGuard = "rateLimitGuard"
        static let globalPassive = "globalPassive"

        // Morning pre-warm
        static let morningPrewarmEnabled = "morningPrewarmEnabled"
        static let morningPrewarmHour = "morningPrewarmHour"
        static let morningPrewarmMinute = "morningPrewarmMinute"
        static let morningPrewarmWeekdaysOnly = "morningPrewarmWeekdaysOnly"
        /// Legacy (pre per-tool) day marker; still read for migration.
        static let lastMorningWarmDayLegacy = "lastMorningWarmDay"

        // Notifications & alerts
        static let notifyWarning = "notifyWarning"
        static let notifyActivated = "notifyActivated"
        static let alertSessionEnabled = "alertSessionEnabled"
        static let alertSessionFirst = "alertSessionFirst"
        static let alertSessionSecond = "alertSessionSecond"
        static let alertWeeklyEnabled = "alertWeeklyEnabled"
        static let alertWeeklyFirst = "alertWeeklyFirst"
        static let alertWeeklySecond = "alertWeeklySecond"
        static let alertPaceEnabled = "alertPaceEnabled"

        // Appearance
        static let colorfulQuotaBars = "colorfulQuotaBars"
        static let appearanceMode = "appearanceMode"
        static let historyRange = "historyRange"
        static let historyProvider = "historyProvider"

        // Hotkey
        static let globalHotKeyEnabled = "globalHotKeyEnabled"
        static let globalHotKeyCode = "globalHotKeyCode"
        static let globalHotKeyModifiers = "globalHotKeyModifiers"

        // App lifecycle
        static let onboardingCompletedVersion = "onboardingCompletedVersion"
        static let onboardingDismissed = "onboardingDismissed"
        static let launchAtLogin = "launchAtLogin"
        static let debugLevel = "debugLevel"
        static let accounts = "accounts.v1"

        // Per provider (`suffix` is `ProviderID.rawValue` == `storageKey`)
        static func toolMode(_ suffix: String) -> String { "toolMode.\(suffix)" }
        /// Pre-`ToolMode` boolean; read once to migrate older installs.
        static func toolActiveLegacy(_ suffix: String) -> String { "toolActive.\(suffix)" }
        static func menuBarVisible(_ suffix: String) -> String { "menuBarVisible.\(suffix)" }
        static func quotaDisplayMode(_ suffix: String) -> String { "quotaDisplayMode.\(suffix)" }
        static func quotaAlertMarks(_ suffix: String) -> String { "quotaAlertMarks.\(suffix)" }
        static func lastAutoWindowKey(_ suffix: String) -> String { "lastAutoWindowKey.\(suffix)" }
        static func lastAutoWarmEndsAt(_ suffix: String) -> String { "lastAutoWarmEndsAt.\(suffix)" }
        static func confirmedWarmupResetAt(_ suffix: String) -> String { "confirmedWarmupResetAt.\(suffix)" }
        static func lastMorningWarmDay(_ suffix: String) -> String { "lastMorningWarmDay.\(suffix)" }
    }

    // MARK: Defaults

    static let defaultRefreshInterval: TimeInterval = 300
    static let defaultWindowDuration: TimeInterval = 5 * 3600
    static let defaultMorningHour = 6
    static let defaultMorningMinute = 0
    static let defaultMorningWeekdaysOnly = true
    static let defaultRateLimitGuard = true

    // MARK: Schema

    var schemaVersion: Int { defaults.object(forKey: Key.schemaVersion) as? Int ?? 0 }

    /// No-op migration hook: every stored value is still in its original
    /// shape. Future format changes add a `if version < N { … }` step here.
    func migrateIfNeeded() {
        let version = schemaVersion
        guard version < Self.currentSchemaVersion else { return }
        // v0 → v1: nothing to rewrite; the version stamp itself is the change.
        defaults.set(Self.currentSchemaVersion, forKey: Key.schemaVersion)
    }

    // MARK: Polling & scheduling

    /// Quota poll period. A stored 0 (or nothing) falls back to 5 minutes.
    var refreshInterval: TimeInterval {
        let stored = defaults.integer(forKey: Key.refreshInterval)
        return stored == 0 ? Self.defaultRefreshInterval : TimeInterval(stored)
    }

    /// Rolling quota window length; the setting exists in case the provider changes it.
    var windowDuration: TimeInterval {
        let stored = defaults.integer(forKey: Key.windowDurationSecs)
        return stored > 0 ? TimeInterval(stored) : Self.defaultWindowDuration
    }

    var rateLimitGuard: Bool {
        defaults.object(forKey: Key.rateLimitGuard) as? Bool ?? Self.defaultRateLimitGuard
    }

    /// The popover's global pause for auto-warm.
    var globalPassive: Bool {
        get { defaults.object(forKey: Key.globalPassive) as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: Key.globalPassive) }
    }

    // MARK: Morning pre-warm

    var morningPrewarmEnabled: Bool {
        get { defaults.bool(forKey: Key.morningPrewarmEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Key.morningPrewarmEnabled) }
    }

    var morningHour: Int { defaults.object(forKey: Key.morningPrewarmHour) as? Int ?? Self.defaultMorningHour }
    var morningMinute: Int { defaults.object(forKey: Key.morningPrewarmMinute) as? Int ?? Self.defaultMorningMinute }
    var morningWeekdaysOnly: Bool {
        defaults.object(forKey: Key.morningPrewarmWeekdaysOnly) as? Bool ?? Self.defaultMorningWeekdaysOnly
    }

    /// Last calendar day (`yyyy-m-d`) a scheduled warm-up succeeded for `suffix`.
    func lastMorningWarmDay(_ suffix: String) -> String? { defaults.string(forKey: Key.lastMorningWarmDay(suffix)) }
    func setLastMorningWarmDay(_ day: String, for suffix: String) {
        defaults.set(day, forKey: Key.lastMorningWarmDay(suffix))
    }
    var lastMorningWarmDayLegacy: String? { defaults.string(forKey: Key.lastMorningWarmDayLegacy) }

    // MARK: Onboarding

    var onboardingCompletedVersion: Int? {
        get { defaults.object(forKey: Key.onboardingCompletedVersion) as? Int }
        nonmutating set { defaults.set(newValue, forKey: Key.onboardingCompletedVersion) }
    }

    var onboardingDismissed: Bool {
        get { defaults.bool(forKey: Key.onboardingDismissed) }
        nonmutating set { defaults.set(newValue, forKey: Key.onboardingDismissed) }
    }
}
