import Foundation

/// Adding, renaming and removing watched accounts, and the inert stand-in a
/// task still in flight for a removed account falls back to. The `accounts` and
/// `toolStates` collections live on `AppState` (Views observe them).
@MainActor
final class AccountsCoordinator {
    enum AccountError: LocalizedError {
        case invalidName
        case invalidHome
        case duplicateHome
        case createFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidName: return "Give the account a name."
            case .invalidHome: return "The folder must be an absolute path without quotes."
            case .duplicateHome: return "Another account already uses this folder."
            case .createFailed(let reason): return "Could not create the folder: \(reason)"
            }
        }
    }

    private unowned let host: CoordinatorHost
    private let scheduler: Scheduler
    private let notifications: NotificationManager
    private var orphanStates: [ProviderID: ToolState] = [:]

    init(host: CoordinatorHost, scheduler: Scheduler, notifications: NotificationManager) {
        self.host = host
        self.scheduler = scheduler
        self.notifications = notifications
    }

    /// The account's live state. A task still in flight for an account that
    /// was just removed gets an inert, unsaved stand-in (mode `.off`), so it
    /// winds down without crashing or re-arming timers.
    func state(for tool: ProviderID) -> ToolState {
        if let state = host.toolStates[tool] { return state }
        if let orphan = orphanStates[tool] { return orphan }
        let orphan = ToolState(orphan: tool)
        orphanStates[tool] = orphan
        return orphan
    }

    /// Adds an account whose CLI home is `home` (created if missing). The new
    /// account starts in Monitor mode; nothing is sent until the user opts in.
    @discardableResult
    func addAccount(kind: ToolID, name: String, home: String) throws -> ProviderID {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw AccountError.invalidName }
        let standardized = (home as NSString).expandingTildeInPath
        let normalized = standardized.count > 1 && standardized.hasSuffix("/")
            ? String(standardized.dropLast()) : standardized
        guard ProviderAccount.isValidHome(normalized) else { throw AccountError.invalidHome }
        let defaultHome = (kind.logDirectoryURL?.deletingLastPathComponent().path) ?? ""
        guard normalized != defaultHome,
              !host.accounts.contains(where: { $0.kind == kind && $0.home == normalized }) else {
            throw AccountError.duplicateHome
        }
        do {
            try FileManager.default.createDirectory(
                atPath: normalized,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw AccountError.createFailed(error.localizedDescription)
        }

        var id = ProviderAccount.slugified(trimmedName)
        if !ProviderAccount.isValidID(id) { id = "acct" }
        let base = id
        var n = 2
        while host.accounts.contains(where: { $0.id == id }) {
            id = "\(base)-\(n)"
            n += 1
        }

        let account = ProviderAccount(id: id, kind: kind, name: trimmedName, home: normalized)
        let provider = account.providerID
        UserDefaults.standard.set(ToolMode.monitor.rawValue, forKey: AppSettings.Key.toolMode(provider.storageKey))
        // Menu-bar space is scarce; an added account is pinned only on request.
        UserDefaults.standard.set(false, forKey: AppSettings.Key.menuBarVisible(provider.storageKey))
        let newState = ToolState(tool: provider)
        host.notifyChange()
        host.accounts.append(account)
        ProviderAccount.save(host.accounts)
        host.toolStates[provider] = newState
        host.events.addHistory(tool: provider, kind: .quotaFetch, title: "Account added", detail: normalized)
        Task { await host.quota.refreshQuota(for: provider, allowAutomaticWarmup: false) }
        return provider
    }

    func renameAccount(_ tool: ProviderID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tool.isDefault, !trimmed.isEmpty,
              let index = host.accounts.firstIndex(where: { $0.id == tool.accountID }) else { return }
        host.notifyChange()
        host.accounts[index].name = trimmed
        ProviderAccount.save(host.accounts)
        host.toolStates[tool]?.tool = host.accounts[index].providerID
    }

    /// Stops watching an added account and forgets its settings. The CLI home
    /// folder (and the login inside it) is left on disk untouched.
    func removeAccount(_ tool: ProviderID) {
        guard !tool.isDefault, let state = host.toolStates[tool] else { return }
        scheduler.invalidate(tool: tool)
        notifications.cancelAll(for: tool)
        state.claimVerifyTask?.cancel()
        state.settleRepollTask?.cancel()
        host.quota.clearAuthRetry(for: state)
        if tool.kind == .claude { CredentialStore().invalidateCachedClaudeCredential(for: tool) }

        let suffix = ".\(tool.storageKey)"
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasSuffix(suffix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        UsageHistoryStore.shared.removeAll(for: tool)
        EventLogStore.shared.removeAll(for: tool)
        host.history.removeAll { $0.tool?.storageKey == tool.storageKey }

        host.notifyChange()
        host.accounts.removeAll { $0.id == tool.accountID }
        ProviderAccount.save(host.accounts)
        host.toolStates[tool] = nil
        host.quota.forgetTokenUsage(for: tool)
        host.quota.exportStatus()
        host.events.addHistory(tool: nil, kind: .quotaFetch, title: "Account removed", detail: tool.displayName)
    }
}
