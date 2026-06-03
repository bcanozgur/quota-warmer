import AppKit
import SwiftUI

struct MenuBarLabel: View {
    @EnvironmentObject var appState: AppState
    @State private var spinDegrees: Double = 0

    private var isActive: Bool {
        appState.isRefreshing || appState.toolStates.values.contains { $0.isWarming || $0.isFetchingQuota }
    }

    private var isHealthy: Bool {
        !appState.globalPassive && appState.toolStates.values.allSatisfy { state in
            if !state.isActive { return true }
            return state.sourceHealth == .healthy && state.freshness == .fresh
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            if let primary = primaryTool {
                toolLabel(primary)
            } else {
                fallbackLabel
            }
        }
        .frame(height: 16)
        .fixedSize()
    }

    private var primaryTool: ToolID? {
        ToolID.allCases
            .map { appState.state(for: $0) }
            .sorted { lhs, rhs in
                score(lhs) > score(rhs)
            }
            .first { $0.isActive || $0.primaryMetric != nil || $0.isFetchingQuota || $0.isWarming }
            .map(\.tool)
    }

    @ViewBuilder
    private var fallbackLabel: some View {
        HStack(spacing: 2) {
            Circle()
                .fill(isHealthy ? DS.C.green : DS.C.red)
                .frame(width: 5.5, height: 5.5)
            Image(systemName: "flame.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DS.C.accent(.claude))
        }
    }

    @ViewBuilder
    private func toolLabel(_ tool: ToolID) -> some View {
        let st = appState.state(for: tool)
        let accent = DS.C.accent(tool)

        HStack(spacing: 3) {
            Circle()
                .fill(statusColor(for: st))
                .frame(width: 5.5, height: 5.5)
            ProviderMenuBarGlyph(tool: tool)
                .opacity(st.isActive || st.freshness == .fresh || st.isWarming ? 1.0 : 0.68)
            if isActive && !st.isWarming {
                Image(systemName: "hourglass")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .rotationEffect(.degrees(spinDegrees))
                    .onAppear {
                        withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                            spinDegrees = 360
                        }
                    }
                    .onDisappear { spinDegrees = 0 }
            }
            if st.isWarming {
                ProgressView()
                    .scaleEffect(0.42)
                    .frame(width: 9, height: 9)
                    .tint(DS.C.blue)
            } else if let r = st.timeUntilReset {
                Text(compactQuotaText(time: r, metric: st.primaryMetric))
                    .font(DS.mono(9, weight: .semibold))
                    .foregroundStyle(timeColor(r, accent: accent))
            } else if st.freshness == .fresh {
                Text("\(Int(st.windowProgress * 100))%")
                    .font(DS.mono(9, weight: .semibold))
                    .foregroundStyle(accent)
            }
        }
    }

    private func score(_ state: ToolState) -> Int {
        if state.isWarming { return 50 }
        if state.isFetchingQuota { return 40 }
        if state.isActive && state.timeUntilReset != nil { return 30 }
        if state.freshness == .fresh { return 20 }
        if state.isActive { return 10 }
        return 0
    }

    private func compactTime(_ secs: TimeInterval) -> String {
        let total = Int(secs)
        let d = total / 86_400
        let h = (total % 86_400) / 3600
        let m = (total % 3600) / 60
        if d > 0 { return "\(d)d\(h)h" }
        return h > 0 ? "\(h)h\(String(format: "%02d", m))m" : "\(m)m"
    }

    private func timeColor(_ r: TimeInterval, accent: Color) -> Color {
        r > 3600 ? accent : r > 1800 ? DS.C.yellow : DS.C.red
    }

    private func statusColor(for state: ToolState) -> Color {
        if appState.globalPassive || !state.isActive { return DS.C.red }
        if state.sourceHealth == .healthy && state.freshness == .fresh { return DS.C.green }
        if state.sourceHealth == .authFailure || state.sourceHealth == .unavailable { return DS.C.red }
        return DS.C.yellow
    }

    private func compactQuotaText(time: TimeInterval, metric: QuotaMetric?) -> String {
        let percent = Int((metric?.remainingFraction ?? 0) * 100)
        return "\(compactTime(time)) - \(percent)%"
    }
}

private struct ProviderMenuBarGlyph: View {
    let tool: ToolID

    var body: some View {
        Image(nsImage: ProviderMenuBarIcon.image(for: tool))
            .resizable()
            .renderingMode(.original)
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 14, height: 14)
            .clipped()
    }
}

private enum ProviderMenuBarIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(for tool: ToolID) -> NSImage {
        let key = tool.rawValue
        if let cached = cache[key] { return cached }
        let name = tool == .claude ? "ClaudeCode" : "Codex"
        let size = NSSize(width: 24, height: 24)
        let output = NSImage(size: size)
        output.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        if let source = NSImage(named: name) {
            source.isTemplate = false
            source.draw(
                in: NSRect(x: 3, y: 3, width: 18, height: 18),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        }
        output.unlockFocus()
        output.isTemplate = false
        cache[key] = output
        return output
    }
}
