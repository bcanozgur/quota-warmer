import Foundation

/// Hands the app's single `AppState` to code the system calls into (App
/// Intents, the URL handler) that has no other way to reach it.
@MainActor
enum IntegrationBridge {
    static var appState: AppState?
}
