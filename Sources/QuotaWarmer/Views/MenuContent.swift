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

extension AppearanceMode {
    /// Applies the theme app-wide. `nil` hands control back to macOS, so the
    /// panel follows System Settings — including live light/dark switches.
    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

enum AppTab: Hashable {
    case main
    case tool(ToolID)
    case settings
}

struct MenuContent: View {
    @EnvironmentObject var appState: AppState
    @AppStorage(AppearanceMode.defaultsKey) private var appearanceRaw = AppearanceMode.system.rawValue

    private var appearance: AppearanceMode { AppearanceMode(rawValue: appearanceRaw) ?? .system }

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
            .padding(2)
            .background(WindowTransparencyConfigurator())
    }

    private var panel: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(DS.C.border)
                .frame(width: 1)
            mainContent
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

            // Theme: System → Light → Dark. The icon shows the current theme.
            SidebarSlot(isSelected: false, help: "Theme: \(appearance.label) — click for \(appearance.next.label)") {
                let next = appearance.next
                appearanceRaw = next.rawValue
                next.apply()
            } icon: {
                Image(systemName: appearance.symbolName)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(DS.C.textSub)
                    .contentTransition(.symbolEffect(.replace))
            }

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
                    onRefresh: { Task { await appState.refreshQuotaManually(for: id) } },
                    isPanelVisible: { appState.isPanelVisible }
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
