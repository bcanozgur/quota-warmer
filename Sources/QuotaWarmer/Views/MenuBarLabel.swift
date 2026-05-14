import SwiftUI

struct MenuBarLabel: View {
    @EnvironmentObject var appState: AppState
    @State private var spinDegrees: Double = 0

    private var isActive: Bool {
        appState.isRefreshing || appState.toolStates.values.contains { $0.isWarming }
    }

    var body: some View {
        HStack(spacing: 5) {
            if isActive {
                Image(systemName: "arrow.2.circlepath")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.C.textSub)
                    .rotationEffect(.degrees(spinDegrees))
                    .onAppear {
                        withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                            spinDegrees = 360
                        }
                    }
                    .onDisappear { spinDegrees = 0 }
            }
            ForEach(ToolID.allCases) { tool in
                toolChip(tool)
            }
        }
    }

    @ViewBuilder
    private func toolChip(_ tool: ToolID) -> some View {
        let st = appState.state(for: tool)
        let accent = DS.C.accent(tool)

        HStack(spacing: 3) {
            Image(tool == .claude ? "ClaudeCode" : "Codex")
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
                .clipped()
                .opacity(st.isWindowActive || st.isWarming ? 1.0 : 0.35)

            if st.isWarming {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 14, height: 14)
                    .tint(DS.C.blue)
            } else if let r = st.timeUntilReset {
                Text(compactTime(r))
                    .font(DS.mono(10, weight: .semibold))
                    .foregroundStyle(timeColor(r, accent: accent))
            } else {
                Text("—")
                    .font(DS.mono(10))
                    .foregroundStyle(DS.C.textMuted)
            }
        }
    }

    private func compactTime(_ secs: TimeInterval) -> String {
        let h = Int(secs) / 3600
        let m = (Int(secs) % 3600) / 60
        return h > 0 ? "\(h)h\(String(format: "%02d", m))m" : "\(m)m"
    }

    private func timeColor(_ r: TimeInterval, accent: Color) -> Color {
        r > 3600 ? accent : r > 1800 ? DS.C.yellow : DS.C.red
    }
}
