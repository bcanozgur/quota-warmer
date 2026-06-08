import AppKit
import Combine
import SwiftUI

/// Owns the menu-bar status item. We use an AppKit `NSStatusItem` (rather than a
/// SwiftUI `MenuBarExtra`) so the icon supports both a left-click panel and a
/// right-click menu. Left-click toggles a borderless panel hosting `MenuContent`;
/// right-click (or control-click) shows the actions menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    private var statusItem: NSStatusItem!
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private var lastCloseAt: Date = .distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationManager.shared.requestPermission()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            button.toolTip = "QuotaWarmer — left-click for stats, right-click for menu"
        }
        statusItem = item
        refreshButtonImage()

        // AppState's 1 s UI timer + quota updates poke objectWillChange; mirror
        // that into the status-item image so the countdowns tick.
        appState.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshButtonImage() }
            .store(in: &cancellables)
    }

    private func refreshButtonImage() {
        statusItem?.button?.image = MenuBarStatus.image(for: appState)
    }

    // MARK: - Click routing

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if isRightClick {
            closePanel()
            showMenu()
        } else {
            togglePanel()
        }
    }

    // MARK: - Panel (left click)

    private func togglePanel() {
        if panel?.isVisible == true {
            closePanel()
        } else if Date().timeIntervalSince(lastCloseAt) >= 0.25 {
            // Guard against immediately reopening when the very click we're
            // handling just dismissed a key panel via windowDidResignKey.
            showPanel()
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let hosting = NSHostingView(rootView: MenuContent().environmentObject(appState))
        hosting.setFrameSize(hosting.fittingSize)
        let created = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        created.contentView = hosting
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = true
        created.level = .popUpMenu
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        created.hidesOnDeactivate = false
        created.delegate = self
        panel = created
        return created
    }

    private func showPanel() {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        let panel = ensurePanel()
        if let hosting = panel.contentView { panel.setContentSize(hosting.fittingSize) }

        let size = panel.frame.size
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var origin = NSPoint(x: buttonRect.midX - size.width / 2, y: buttonRect.minY - size.height - 2)
        if let screen = buttonWindow.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 6), visible.maxX - size.width - 6)
        }
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
    }

    private func closePanel() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        lastCloseAt = Date()
    }

    // MARK: - Menu (right click)

    private func showMenu() {
        guard let button = statusItem?.button else { return }
        let menu = NSMenu()
        menu.addItem(makeItem("Show Stats", #selector(showStats)))
        menu.addItem(makeItem("Go to Settings", #selector(goToSettings)))

        let debug = NSMenuItem(title: "Debug Level", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for level in DebugLevel.allCases {
            let entry = makeItem(level.title, #selector(setDebugLevel(_:)))
            entry.state = (DebugLevel.current == level) ? .on : .off
            entry.representedObject = level.rawValue
            submenu.addItem(entry)
        }
        debug.submenu = submenu
        menu.addItem(debug)

        menu.addItem(.separator())
        menu.addItem(makeItem("About QuotaWarmer", #selector(showAbout)))
        menu.addItem(makeItem("Quit", #selector(quit), key: "q"))

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 6), in: button)
    }

    private func makeItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func showStats() {
        appState.selectedTab = .main
        showPanel()
    }

    @objc private func goToSettings() {
        appState.selectedTab = .settings
        showPanel()
    }

    @objc private func setDebugLevel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int, let level = DebugLevel(rawValue: raw) else { return }
        DebugLevel.current = level
        DiagnosticLogger.append("debug_level_changed level=\(level.title.lowercased())")
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        closePanel()
    }
}

/// Borderless panel that can still become key so the hosted SwiftUI controls
/// (buttons, steppers, fields) stay interactive.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
