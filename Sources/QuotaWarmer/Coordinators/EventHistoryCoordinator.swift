import Foundation

/// The in-memory event list the History tab shows plus its on-disk mirror
/// (`events.jsonl` via `EventLogStore`). `AppState.history` holds the array so
/// views can observe it; this type owns how it is appended and restored.
@MainActor
final class EventHistoryCoordinator {
    /// Newest events kept in memory for the UI; the full log lives on disk.
    static let historyInMemory = 500

    private unowned let host: CoordinatorHost

    init(host: CoordinatorHost) {
        self.host = host
    }

    func addHistory(
        tool: ProviderID?, kind: HistoryKind, title: String, detail: String,
        outcome: EventOutcome? = nil, windowKey: String? = nil, windowResetAt: Date? = nil, model: String? = nil,
        source: WarmupSource? = nil
    ) {
        // An in-flight task for a just-removed account must not resurrect its events.
        if let tool, host.toolStates[tool] == nil { return }
        let event = HistoryEvent(
            tool: tool, kind: kind, title: title, detail: detail,
            outcome: outcome, windowKey: windowKey, windowResetAt: windowResetAt, model: model, source: source
        )
        host.history.insert(event, at: 0)
        if host.history.count > Self.historyInMemory { host.history.removeLast(host.history.count - Self.historyInMemory) }
        EventLogStore.shared.append(event)
        DiagnosticLogger.appendHistory(event)
    }

    /// Fills `history` from `events.jsonl` (pruning it) without losing events
    /// recorded while the file was loading. Events of accounts that no longer
    /// exist are dropped; the rest get their full `ProviderID` back.
    func loadPersistedHistory() {
        Task { [weak self] in
            let loaded = await EventLogStore.shared.loadAndPrune()
            guard let self else { return }
            let host = self.host
            let known = Dictionary(uniqueKeysWithValues: host.providers.map { ($0.storageKey, $0) })
            let restored = loaded.reversed().compactMap { event -> HistoryEvent? in
                guard let key = event.tool?.storageKey else { return event }
                guard let provider = known[key] else { return nil }
                return HistoryEvent(
                    id: event.id, timestamp: event.timestamp, tool: provider, kind: event.kind,
                    title: event.title, detail: event.detail, outcome: event.outcome,
                    windowKey: event.windowKey, windowResetAt: event.windowResetAt, model: event.model,
                    source: event.source
                )
            }
            let fresh = Set(host.history.map(\.id))
            host.history = Array((host.history + restored.filter { !fresh.contains($0.id) })
                .prefix(Self.historyInMemory))
        }
    }
}
