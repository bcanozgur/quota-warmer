import Foundation

/// What the coordinators need from `AppState`, and nothing more. `AppState`
/// stays the `ObservableObject` Views observe and owns the published state;
/// the coordinators own the behavior and reach that state only through this
/// protocol (and through each other for the few cross-cutting calls, e.g. a
/// poll that may start an automatic warm-up).
@MainActor
protocol CoordinatorHost: AnyObject {
    var settings: AppSettings { get }

    // Published state owned by AppState.
    var providers: [ProviderID] { get }
    var toolStates: [ProviderID: ToolState] { get set }
    var accounts: [ProviderAccount] { get set }
    var history: [HistoryEvent] { get set }
    var globalPassive: Bool { get }
    var lastSuccessfulPollAt: Date? { get set }
    var morningPrewarmEnabled: Bool { get set }
    var morningStatus: String? { get set }
    var isRefreshing: Bool { get set }

    func state(for tool: ProviderID) -> ToolState
    /// Publishes a change to views that observe `AppState` rather than each `ToolState`.
    func notifyChange()

    // Sibling coordinators.
    var events: EventHistoryCoordinator { get }
    var quota: QuotaPollingCoordinator { get }
    var warmup: WarmupCoordinator { get }
    var morning: MorningCoordinator { get }
}
