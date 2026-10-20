import Foundation

/// Entry points for the URL scheme and App Intents. Everything here is a thin
/// wrapper over existing AppState paths so their guards still apply.
extension AppState {
    /// The watched account for a `ProviderID.storageKey`, nil if unknown.
    func provider(forKey key: String) -> ProviderID? {
        let wanted = key.lowercased()
        return providers.first { $0.storageKey.lowercased() == wanted }
    }

    /// Latest reading per account in the `status.json` shape.
    func statusProviders(now: Date = Date()) -> [QuotaStatusProvider] {
        providers.compactMap { provider in
            guard let state = toolStates[provider] else { return nil }
            return QuotaStatusExport.provider(
                QuotaStatusExport.Entry(
                    provider: provider,
                    mode: state.mode,
                    displayMode: state.displayMode,
                    pinned: state.menuBarVisible,
                    snapshot: state.quotaSnapshot
                ),
                now: now
            )
        }
    }

    /// Refreshes monitored accounts (one key, or all) like a timer poll would:
    /// an outstanding rate-limit backoff is respected, no Keychain prompt can
    /// appear, no warm-up can start, and a given account is refreshed at most
    /// once per `IntegrationRefreshThrottle.minimumInterval`. Returns the
    /// accounts actually refreshed.
    @discardableResult
    func refreshFromIntegration(providerKey: String?) async -> [ProviderID] {
        let targets: [ProviderID]
        if let providerKey {
            guard let one = provider(forKey: providerKey) else { return [] }
            targets = [one]
        } else {
            targets = providers
        }
        let allowed = targets.filter {
            state(for: $0).isMonitored && IntegrationRefreshGate.allow($0.storageKey)
        }
        await withTaskGroup(of: Void.self) { group in
            for tool in allowed {
                group.addTask { @MainActor in
                    await self.refreshQuota(for: tool, allowAutomaticWarmup: false)
                }
            }
        }
        return allowed
    }

    /// Shortcuts / hotkey "pause all auto-warm" (the popover's global pause).
    func setAutoWarmPaused(_ paused: Bool) {
        guard globalPassive != paused else { return }
        globalPassive = paused
    }

    /// The popover's Warm button path (`activate` → `triggerWarmup`, "manual"),
    /// awaited. Returns false if a warm-up for this account is already running.
    func warmUpNow(_ tool: ProviderID) async -> Bool {
        guard !state(for: tool).isWarming else { return false }
        return await triggerWarmup(tool: tool, mode: "manual")
    }
}

@MainActor
enum IntegrationRefreshGate {
    private static var throttle = IntegrationRefreshThrottle()
    static func allow(_ key: String) -> Bool { throttle.allow(key) }
}
