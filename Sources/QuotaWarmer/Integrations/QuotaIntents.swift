import AppIntents
import Foundation

// MARK: - Entities

/// One watched account, as picked in Shortcuts.
struct QuotaAccountEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Account"
    static var defaultQuery = QuotaAccountQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct QuotaAccountQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [QuotaAccountEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [QuotaAccountEntity] {
        guard let appState = IntegrationBridge.appState else { return [] }
        return appState.providers.map { QuotaAccountEntity(id: $0.storageKey, name: $0.displayName) }
    }
}

/// The result of Get Quota: percents are whole numbers as the app shows them;
/// a missing window (no reading yet) leaves its fields empty.
struct QuotaReadingEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Quota Reading"
    static var defaultQuery = QuotaReadingQuery()

    var id: String
    @Property(title: "Account") var account: String
    @Property(title: "Mode") var mode: String
    @Property(title: "Freshness") var freshness: String
    @Property(title: "Session Used (%)") var sessionUsedPercent: Int?
    @Property(title: "Session Left (%)") var sessionLeftPercent: Int?
    @Property(title: "Session Resets At") var sessionResetsAt: Date?
    @Property(title: "Weekly Used (%)") var weeklyUsedPercent: Int?
    @Property(title: "Weekly Left (%)") var weeklyLeftPercent: Int?
    @Property(title: "Weekly Resets At") var weeklyResetsAt: Date?
    @Property(title: "Summary") var summary: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(account)", subtitle: "\(summary)")
    }

    init(_ status: QuotaStatusProvider) {
        id = status.id
        account = status.name
        mode = status.mode
        freshness = status.freshness
        sessionUsedPercent = status.session?.usedPercent
        sessionLeftPercent = status.session?.remainingPercent
        sessionResetsAt = status.session?.resetAt
        weeklyUsedPercent = status.weekly?.usedPercent
        weeklyLeftPercent = status.weekly?.remainingPercent
        weeklyResetsAt = status.weekly?.resetAt
        summary = Self.summary(for: status)
    }

    static func summary(for status: QuotaStatusProvider) -> String {
        guard status.session != nil || status.weekly != nil else {
            return "\(status.name): no quota reading yet."
        }
        func part(_ label: String, _ window: QuotaStatusWindow?) -> String? {
            guard let window else { return nil }
            if window.settling { return "\(label) just reset" }
            if window.idle { return "\(label) not started (100% left)" }
            return "\(label) \(window.usedPercent)% used, \(window.remainingPercent)% left"
        }
        let body = [part("Session", status.session), part("Weekly", status.weekly)]
            .compactMap { $0 }.joined(separator: "; ")
        let stale = status.freshness == "fresh" ? "" : " (\(status.freshness) reading)"
        return "\(status.name): \(body)\(stale)."
    }
}

struct QuotaReadingQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [QuotaReadingEntity] {
        guard let appState = IntegrationBridge.appState else { return [] }
        return appState.statusProviders().filter { identifiers.contains($0.id) }.map(QuotaReadingEntity.init)
    }
}

enum QuotaModeOption: String, AppEnum {
    case off, monitor, autoWarm

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Mode"
    static var caseDisplayRepresentations: [QuotaModeOption: DisplayRepresentation] = [
        .off: "Off",
        .monitor: "Monitor",
        .autoWarm: "Auto-warm"
    ]

    var toolMode: ToolMode {
        switch self {
        case .off: return .off
        case .monitor: return .monitor
        case .autoWarm: return .autoWarm
        }
    }
}

enum IntegrationIntentError: Error, CustomLocalizedStringResourceConvertible {
    case appNotReady
    case unknownAccount

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotReady: return "QuotaWarmer is not ready yet. Try again in a moment."
        case .unknownAccount: return "That account is no longer in QuotaWarmer."
        }
    }
}

@MainActor
private func resolve(_ account: QuotaAccountEntity) throws -> (AppState, ProviderID) {
    guard let appState = IntegrationBridge.appState else { throw IntegrationIntentError.appNotReady }
    guard let provider = appState.provider(forKey: account.id) else { throw IntegrationIntentError.unknownAccount }
    return (appState, provider)
}

// MARK: - Intents

struct GetQuotaIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Quota"
    static var description = IntentDescription(
        "Reads the latest session (5h) and weekly quota for an account: used and left percent, reset time and freshness."
    )

    @Parameter(title: "Account") var account: QuotaAccountEntity

    static var parameterSummary: some ParameterSummary { Summary("Get quota for \(\.$account)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<QuotaReadingEntity> & ProvidesDialog {
        let (appState, provider) = try resolve(account)
        guard let status = appState.statusProviders().first(where: { $0.id == provider.storageKey }) else {
            throw IntegrationIntentError.unknownAccount
        }
        let reading = QuotaReadingEntity(status)
        return .result(value: reading, dialog: "\(reading.summary)")
    }
}

struct RefreshQuotaIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Quota"
    static var description = IntentDescription(
        "Refreshes quota now. Respects the rate-limit backoff and never starts a warm-up."
    )

    @Parameter(title: "Account", description: "Leave empty to refresh every monitored account.")
    var account: QuotaAccountEntity?

    static var parameterSummary: some ParameterSummary { Summary("Refresh quota for \(\.$account)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appState = IntegrationBridge.appState else { throw IntegrationIntentError.appNotReady }
        let refreshed = await appState.refreshFromIntegration(providerKey: account?.id)
        if refreshed.isEmpty {
            return .result(dialog: "Nothing refreshed: the account is off, or it was refreshed within the last 30 seconds.")
        }
        return .result(dialog: "Refreshed \(refreshed.map(\.shortName).joined(separator: ", ")).")
    }
}

struct SetQuotaModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Mode"
    static var description = IntentDescription("Sets an account to Off, Monitor or Auto-warm.")

    @Parameter(title: "Account") var account: QuotaAccountEntity
    @Parameter(title: "Mode") var mode: QuotaModeOption

    static var parameterSummary: some ParameterSummary { Summary("Set \(\.$account) to \(\.$mode)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (appState, provider) = try resolve(account)
        appState.setMode(mode.toolMode, for: provider)
        return .result(dialog: "\(provider.shortName) is now \(mode.toolMode.label).")
    }
}

struct PauseAutoWarmIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause Auto-warm"
    static var description = IntentDescription("Pauses automatic warm-ups for every account until resumed.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appState = IntegrationBridge.appState else { throw IntegrationIntentError.appNotReady }
        appState.setAutoWarmPaused(true)
        return .result(dialog: "Auto-warm is paused.")
    }
}

struct ResumeAutoWarmIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Auto-warm"
    static var description = IntentDescription("Resumes automatic warm-ups for every account.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appState = IntegrationBridge.appState else { throw IntegrationIntentError.appNotReady }
        appState.setAutoWarmPaused(false)
        return .result(dialog: "Auto-warm is resumed.")
    }
}

struct WarmUpNowIntent: AppIntent {
    static var title: LocalizedStringResource = "Warm Up Now"
    static var description = IntentDescription(
        "Sends the minimal warm-up message to start a fresh quota window now. Asks for confirmation first."
    )

    @Parameter(title: "Account") var account: QuotaAccountEntity

    static var parameterSummary: some ParameterSummary { Summary("Warm up \(\.$account) now") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (appState, provider) = try resolve(account)
        try await requestConfirmation(
            result: .result(dialog: "Send a warm-up message to \(provider.shortName) now? It uses a small amount of quota.")
        )
        guard await appState.warmUpNow(provider) else {
            return .result(dialog: "A warm-up for \(provider.shortName) is already running.")
        }
        return .result(dialog: "Warm-up sent to \(provider.shortName).")
    }
}

// MARK: - Shortcuts

struct QuotaWarmerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetQuotaIntent(),
            phrases: ["Get quota in \(.applicationName)", "Check my quota in \(.applicationName)"],
            shortTitle: "Get Quota",
            systemImageName: "gauge.with.dots.needle.67percent"
        )
        AppShortcut(
            intent: RefreshQuotaIntent(),
            phrases: ["Refresh quota in \(.applicationName)"],
            shortTitle: "Refresh Quota",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: PauseAutoWarmIntent(),
            phrases: ["Pause auto-warm in \(.applicationName)"],
            shortTitle: "Pause Auto-warm",
            systemImageName: "pause.circle"
        )
        AppShortcut(
            intent: ResumeAutoWarmIntent(),
            phrases: ["Resume auto-warm in \(.applicationName)"],
            shortTitle: "Resume Auto-warm",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: WarmUpNowIntent(),
            phrases: ["Warm up now in \(.applicationName)"],
            shortTitle: "Warm Up Now",
            systemImageName: "flame"
        )
        AppShortcut(
            intent: SetQuotaModeIntent(),
            phrases: ["Set mode in \(.applicationName)"],
            shortTitle: "Set Mode",
            systemImageName: "slider.horizontal.3"
        )
    }
}
