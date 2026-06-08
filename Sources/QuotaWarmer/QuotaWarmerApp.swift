import SwiftUI

@main
struct QuotaWarmerApp: App {
    // The menu-bar status item, its left-click panel, and right-click menu are
    // all managed by the AppDelegate (AppKit), so the icon can support both a
    // panel and a context menu — which SwiftUI's MenuBarExtra cannot.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
