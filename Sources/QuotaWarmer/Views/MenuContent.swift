import SwiftUI
import AppKit

// Makes the hosting NSWindow transparent so our rounded corners don't bleed.
private struct WindowTransparencyConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = true
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

enum AppTab: Hashable {
    case main
    case tool(ToolID)
    case settings
}

struct MenuContent: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: AppTab = .main
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                Rectangle()
                    .fill(DS.C.border)
                    .frame(width: 1)
                mainContent
            }
            footerStrip
        }
        .frame(width: DS.totalWidth)
        .frame(height: DS.totalHeight)
        .background(DS.C.bg)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 18, x: 0, y: 6)
        .background(WindowTransparencyConfigurator())
        .onReceive(ticker) { t in now = t }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 28) {
            SidebarMainTab(isSelected: selectedTab == .main) {
                selectedTab = .main
            }

            ForEach(ToolID.allCases) { tool in
                SidebarTab(
                    tool: tool,
                    toolState: appState.state(for: tool),
                    isSelected: selectedTab == .tool(tool)
                ) { selectedTab = .tool(tool) }
            }

            Spacer()

            SidebarSettingsTab(isSelected: selectedTab == .settings) {
                selectedTab = .settings
            }
        }
        .padding(.top, 46)
        .padding(.bottom, 34)
        .frame(width: DS.sidebarWidth)
        .background(DS.C.sidebar)
    }

    // MARK: - Main content

    @ViewBuilder
    private var mainContent: some View {
        switch selectedTab {
        case .main:
            MainTabView()
                .frame(width: DS.contentWidth)
                .frame(maxHeight: .infinity)
        case .tool(let id):
            if appState.showOnboarding {
                OnboardingView()
                    .frame(width: DS.contentWidth)
                    .frame(maxHeight: .infinity)
                    .transition(.opacity)
            } else {
                ToolTabView(
                    toolState: appState.state(for: id),
                    onActivate: { appState.activate(id) },
                    onRefresh: { Task { await appState.refreshQuota(for: id) } }
                )
                .frame(width: DS.contentWidth)
                .frame(maxHeight: .infinity)
                .id(id)
            }
        case .settings:
            SettingsTabView()
                .frame(width: DS.contentWidth)
                .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Footer

    private var footerStrip: some View {
        HStack(spacing: 12) {
            if let update = appState.updateInfo {
                Button(action: { NSWorkspace.shared.open(update.htmlURL) }) {
                    Text("Restart to update")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                        .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            } else if case .tool(let tool) = selectedTab {
                Button(action: { appState.activate(tool) }) {
                    Text("Warm now")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(DS.C.text)
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                        .background(DS.C.track, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            } else {
                Text("QuotaWarmer v\(appVersion)")
                    .font(.system(size: 18))
                    .foregroundStyle(DS.C.textMuted)
            }

            Spacer()

            Text(footerStatus)
                .font(.system(size: 22))
                .foregroundStyle(DS.C.textSub)
        }
        .frame(height: 72)
        .padding(.horizontal, 24)
        .background(DS.C.bg)
        .overlay(Rectangle().fill(DS.C.border).frame(height: 1), alignment: .top)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var footerStatus: String {
        if case .tool(let tool) = selectedTab {
            let state = appState.state(for: tool)
            if state.isFetchingQuota { return "Updating..." }
            if let next = state.nextRefreshAt { return "Next update in \(compactCountdown(next))" }
        }
        return appState.globalPassive ? "Passive" : "Polling"
    }

    private func compactCountdown(_ date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}

// MARK: - SidebarTab

struct SidebarTab: View {
    let tool: ToolID
    @ObservedObject var toolState: ToolState
    let isSelected: Bool
    let action: () -> Void

    private var accent: Color { DS.C.accent(tool) }

    private var dotColor: Color? {
        if toolState.isWarming { return DS.C.blue }
        if toolState.isActive && toolState.freshness == .fresh { return DS.C.green }
        if toolState.sourceHealth == .authFailure || toolState.freshness == .expired { return DS.C.red }
        return nil
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(DS.C.ink)
                        .frame(width: 4, height: 64)
                        .offset(x: -1)
                }
                Image(tool == .claude ? "ClaudeCode" : "Codex")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                    .opacity(toolState.isActive || toolState.isWarming || isSelected ? 1.0 : 0.72)
                    .frame(maxWidth: .infinity)

                if let dot = dotColor {
                    Circle()
                        .fill(dot)
                        .frame(width: 7, height: 7)
                        .offset(x: 58, y: -18)
                }
            }
            .frame(width: DS.sidebarWidth, height: 62)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - SidebarMainTab

struct SidebarMainTab: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            sidebarIcon(systemName: "house", selected: isSelected)
        }
        .buttonStyle(.plain)
    }

    private func sidebarIcon(systemName: String, selected: Bool) -> some View {
        ZStack(alignment: .leading) {
            if selected {
                RoundedRectangle(cornerRadius: 2)
                    .fill(DS.C.ink)
                    .frame(width: 4, height: 64)
                    .offset(x: -1)
            }
            Image(systemName: systemName)
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(selected ? DS.C.ink : DS.C.textSub)
                .frame(maxWidth: .infinity)
        }
        .frame(width: DS.sidebarWidth, height: 62)
    }
}

// MARK: - SidebarSettingsTab

struct SidebarSettingsTab: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(DS.C.ink)
                        .frame(width: 4, height: 64)
                        .offset(x: -1)
                }
                Image(systemName: "gearshape")
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(isSelected ? DS.C.ink : DS.C.textSub)
                    .frame(maxWidth: .infinity)
            }
            .frame(width: DS.sidebarWidth, height: 62)
        }
        .buttonStyle(.plain)
    }
}
