import SwiftUI
import AppKit
import ServiceManagement

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
    case tool(ToolID)
    case settings
}

struct MenuContent: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: AppTab = .tool(.claude)

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
        .background(DS.C.bg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 18, x: 0, y: 6)
        .background(WindowTransparencyConfigurator())
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Brand
            Image(systemName: "flame.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.C.accent(.claude))
                .frame(width: DS.sidebarWidth, height: DS.sidebarWidth)
                .background(DS.C.surface)

            Rectangle().fill(DS.C.border).frame(height: 1)

            ForEach(ToolID.allCases) { tool in
                SidebarTab(
                    tool: tool,
                    toolState: appState.state(for: tool),
                    isSelected: selectedTab == .tool(tool)
                ) { selectedTab = .tool(tool) }
            }

            Spacer()

            Rectangle().fill(DS.C.border).frame(height: 1)

            SidebarSettingsTab(isSelected: selectedTab == .settings) {
                selectedTab = .settings
            }
        }
        .frame(width: DS.sidebarWidth)
        .background(DS.C.surface)
    }

    // MARK: - Main content

    @ViewBuilder
    private var mainContent: some View {
        switch selectedTab {
        case .tool(let id):
            if appState.showOnboarding {
                OnboardingView()
                    .frame(width: DS.contentWidth)
                    .transition(.opacity)
            } else {
                ToolTabView(
                    toolState: appState.state(for: id),
                    onActivate: { appState.activate(id) }
                )
                .frame(width: DS.contentWidth)
                .id(id)
            }
        case .settings:
            SettingsTabView()
                .frame(width: DS.contentWidth)
        }
    }

    // MARK: - Footer

    private var footerStrip: some View {
        HStack {
            Text("QuotaWarmer v\(appVersion)")
                .font(.system(size: 10))
                .foregroundStyle(DS.C.textMuted)

            Spacer()

            if let update = appState.updateInfo {
                Button(action: { NSWorkspace.shared.open(update.htmlURL) }) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 9))
                        Text("v\(update.version) available")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(DS.C.accent(.claude))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, 7)
        .background(DS.C.surface)
        .overlay(Rectangle().fill(DS.C.border).frame(height: 1), alignment: .top)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
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
        if toolState.isWindowActive { return DS.C.green }
        return nil
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(tool == .claude ? "ClaudeCode" : "Codex")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .opacity(toolState.isWindowActive || toolState.isWarming ? 1.0 : 0.28)

                if let dot = dotColor {
                    Circle()
                        .fill(dot)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().stroke(DS.C.surface, lineWidth: 1.5))
                        .offset(x: 3, y: -3)
                }
            }
            .frame(width: DS.sidebarWidth, height: DS.sidebarWidth)
            .background(isSelected ? accent.opacity(0.08) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 1)
                    .fill(isSelected ? accent : .clear)
                    .frame(width: 2)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading),
                alignment: .leading
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - SidebarSettingsTab

struct SidebarSettingsTab: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 15))
                .foregroundStyle(isSelected ? DS.C.text : DS.C.textMuted)
                .frame(width: DS.sidebarWidth, height: DS.sidebarWidth)
                .background(isSelected ? DS.C.surfaceHigh : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 1)
                        .fill(isSelected ? DS.C.textSub : .clear)
                        .frame(width: 2)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading),
                    alignment: .leading
                )
        }
        .buttonStyle(.plain)
    }
}
