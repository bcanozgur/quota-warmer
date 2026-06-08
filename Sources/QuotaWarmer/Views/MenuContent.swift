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
            .clipShape(RoundedRectangle(cornerRadius: DS.R.xl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.R.xl, style: .continuous)
                    .stroke(DS.C.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 8)
            .padding(2)
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
        VStack(spacing: 6) {
            SidebarSlot(isSelected: appState.selectedTab == .main, help: "Overview") {
                appState.selectedTab = .main
            } icon: {
                Image(systemName: appState.selectedTab == .main ? "house.fill" : "house")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(appState.selectedTab == .main ? DS.C.ink : DS.C.textSub)
            }

            ForEach(ToolID.allCases) { tool in
                SidebarToolItem(
                    tool: tool,
                    toolState: appState.state(for: tool),
                    isSelected: appState.selectedTab == .tool(tool)
                ) { appState.selectedTab = .tool(tool) }
            }

            Spacer()

            SidebarSlot(isSelected: appState.selectedTab == .settings, help: "Settings") {
                appState.selectedTab = .settings
            } icon: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(appState.selectedTab == .settings ? DS.C.ink : DS.C.textSub)
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 14)
        .frame(width: DS.sidebarWidth)
        .background(DS.C.sidebar)
    }

    // MARK: - Main content

    @ViewBuilder
    private var mainContent: some View {
        switch appState.selectedTab {
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
                    onSetMode: { appState.setMode($0, for: id) },
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
            if let warning = appState.watcherStatusText {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(warning)
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(DS.C.yellow)
                .help("QuotaWarmer hasn't completed a quota check recently — it may be offline or blocked.")
            } else if let update = appState.updateInfo {
                Button(action: { NSWorkspace.shared.open(update.htmlURL) }) {
                    Text("Restart to update")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.C.red)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(DS.C.red.opacity(0.10), in: Capsule())
                        .overlay(Capsule().stroke(DS.C.red.opacity(0.22), lineWidth: 1))
                }
                .buttonStyle(PressableButtonStyle())
            } else {
                Text("QuotaWarmer v\(appVersion)")
                    .font(.system(size: 11.5, weight: .medium))
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
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(DS.C.textSub)
            }
            .buttonStyle(.plain)
            .disabled(!canRefreshFromFooter)
        }
        .frame(height: 38)
        .padding(.horizontal, 12)
        .background(DS.C.bg)
        .overlay(Rectangle().fill(DS.C.border).frame(height: 1), alignment: .top)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var footerStatus: String {
        if case .tool(let tool) = appState.selectedTab {
            let state = appState.state(for: tool)
            if state.isFetchingQuota { return "Updating..." }
            if let next = state.nextRefreshAt { return "Next update in \(compactCountdown(next))" }
        }
        return "Idle"
    }

    private var isFooterRefreshing: Bool {
        if case .tool(let tool) = appState.selectedTab {
            return appState.state(for: tool).isFetchingQuota
        }
        return appState.isRefreshing
    }

    private var canRefreshFromFooter: Bool {
        if case .tool = appState.selectedTab { return true }
        return false
    }

    private func footerAction() {
        guard case .tool(let tool) = appState.selectedTab else { return }
        Task { await appState.refreshQuota(for: tool) }
    }

    private func compactCountdown(_ date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}

// MARK: - Sidebar items

/// One icon slot in the narrow left rail. Selected state is shown with a soft
/// rounded highlight (OpenUsage-style) rather than a colored bar; hover gives a
/// faint highlight. Holds any icon (SF Symbol or template provider glyph).
struct SidebarSlot<Icon: View>: View {
    let isSelected: Bool
    let help: String
    let action: () -> Void
    @ViewBuilder var icon: () -> Icon

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            icon()
                .frame(width: 38, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(highlight)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(isSelected ? DS.C.border : Color.clear, lineWidth: 1)
                )
                .frame(width: DS.sidebarWidth, height: 36)
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(Text(help))
    }

    private var highlight: Color {
        if isSelected { return DS.C.surface }
        if hovering { return DS.C.surfaceHigh }
        return .clear
    }
}

/// Provider glyph slot in the sidebar. Observes the tool so the icon dims when
/// the tool isn't being monitored. Keeps the Claude/Codex glyphs untouched.
struct SidebarToolItem: View {
    let tool: ToolID
    @ObservedObject var toolState: ToolState
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        SidebarSlot(isSelected: isSelected, help: tool.shortName, action: action) {
            Image(tool == .claude ? "ClaudeCode" : "Codex")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 19, height: 19)
                .foregroundStyle(isSelected ? DS.C.ink : DS.C.text)
                .opacity(toolState.isMonitored || toolState.isWarming || isSelected ? 1.0 : 0.55)
        }
    }
}
