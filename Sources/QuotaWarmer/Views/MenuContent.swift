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
        panel
            .frame(width: DS.totalWidth, height: DS.totalHeight)
            .scaleEffect(DS.panelScale, anchor: .topLeading)
            .frame(
                width: DS.totalWidth * DS.panelScale,
                height: DS.totalHeight * DS.panelScale,
                alignment: .topLeading
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
            .background(WindowTransparencyConfigurator())
            .onReceive(ticker) { t in now = t }
    }

    private var panel: some View {
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
        .background(DS.C.bg)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 18) {
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
        .padding(.top, 26)
        .padding(.bottom, 26)
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
            VStack(spacing: 0) {
                if appState.showOnboarding {
                    OnboardingView()
                        .transition(.opacity)
                }
                ToolTabView(
                    toolState: appState.state(for: id),
                    onSetActive: { appState.setActive($0, for: id) },
                    onActivate: { appState.activate(id) },
                    onRefresh: { Task { await appState.refreshQuota(for: id) } }
                )
                .frame(width: DS.contentWidth)
                .frame(maxHeight: .infinity)
                .id(id)
            }
            .frame(width: DS.contentWidth)
            .frame(maxHeight: .infinity)
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
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: DS.R.md))
                }
                .buttonStyle(.plain)
            } else {
                Text("QuotaWarmer v\(appVersion)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.C.textMuted)
            }

            Spacer()

            Button(action: footerAction) {
                HStack(spacing: 5) {
                    if isFooterRefreshing {
                        Image(systemName: "hourglass")
                            .font(.system(size: 11, weight: .medium))
                    }
                    Text(footerStatus)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.C.textSub)
            }
            .buttonStyle(.plain)
            .disabled(!canRefreshFromFooter)
        }
        .frame(height: 46)
        .padding(.horizontal, 18)
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
        return "Ready"
    }

    private var isFooterRefreshing: Bool {
        if case .tool(let tool) = selectedTab {
            return appState.state(for: tool).isFetchingQuota
        }
        return appState.isRefreshing
    }

    private var canRefreshFromFooter: Bool {
        if case .tool = selectedTab { return true }
        return false
    }

    private func footerAction() {
        guard case .tool(let tool) = selectedTab else { return }
        Task { await appState.refreshQuota(for: tool) }
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

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(DS.C.ink)
                    .frame(width: 3, height: 42)
                        .offset(x: -1)
                }
                Image(tool == .claude ? "ClaudeCode" : "Codex")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 25, height: 25)
                    .foregroundStyle(tool == .claude ? DS.C.accent(.claude) : Color(red: 0.39, green: 0.70, blue: 0.64))
                    .opacity(toolState.isActive || toolState.isWarming || isSelected ? 1.0 : 0.72)
                    .frame(maxWidth: .infinity)
            }
            .frame(width: DS.sidebarWidth, height: 48)
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
            sidebarIcon(systemName: "gauge.with.dots.needle.50percent", selected: isSelected)
        }
        .buttonStyle(.plain)
    }

    private func sidebarIcon(systemName: String, selected: Bool) -> some View {
        ZStack(alignment: .leading) {
            if selected {
                RoundedRectangle(cornerRadius: 2)
                    .fill(DS.C.ink)
                    .frame(width: 3, height: 42)
                    .offset(x: -1)
            }
            Image(systemName: systemName)
                .font(.system(size: 25, weight: .regular))
                .foregroundStyle(selected ? DS.C.ink : DS.C.textSub)
                .frame(maxWidth: .infinity)
        }
        .frame(width: DS.sidebarWidth, height: 48)
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
                    .frame(width: 3, height: 42)
                    .offset(x: -1)
            }
            Image(systemName: "gearshape")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(isSelected ? DS.C.ink : DS.C.textSub)
                    .frame(maxWidth: .infinity)
            }
            .frame(width: DS.sidebarWidth, height: 48)
        }
        .buttonStyle(.plain)
    }
}
