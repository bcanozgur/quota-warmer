import Foundation

/// Applies a parsed `quotawarmer://` command. Read/open/refresh only; see
/// `IntegrationCommand` for why nothing here can warm up or change settings.
@MainActor
enum IntegrationURLHandler {
    static func handle(_ urls: [URL], appState: AppState, showPanel: @escaping (AppTab?) -> Void) {
        for url in urls {
            guard let command = IntegrationURL.parse(url) else {
                DiagnosticLogger.append("url_scheme_rejected")
                continue
            }
            switch command {
            case .open(let tab):
                DiagnosticLogger.append("url_scheme_open tab=\(tab?.rawValue ?? "-")")
                switch tab {
                case .main: showPanel(.main)
                case .history: showPanel(.history)
                case .settings: showPanel(.settings)
                case nil: showPanel(nil)
                }
            case .refresh(let key):
                DiagnosticLogger.append("url_scheme_refresh provider=\(key ?? "all")")
                Task { await appState.refreshFromIntegration(providerKey: key) }
            }
        }
    }
}
