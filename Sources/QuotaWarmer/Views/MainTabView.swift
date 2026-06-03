import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                header
                ForEach(ToolID.allCases) { tool in
                    toolCard(tool)
                }
                historySection
            }
            .padding(DS.Space.lg)
        }
        .background(DS.C.bg)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("MAIN")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DS.C.textMuted)
                Text("Live quota checks control warmups")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.C.textSub)
            }
            Spacer()
            Toggle("", isOn: $appState.globalPassive)
                .toggleStyle(.switch)
                .scaleEffect(0.72)
                .tint(DS.C.red)
            Text(appState.globalPassive ? "Passive" : "Polling")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(appState.globalPassive ? DS.C.red : DS.C.green)
        }
    }

    private func toolCard(_ tool: ToolID) -> some View {
        let state = appState.state(for: tool)
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(tool == .claude ? "ClaudeCode" : "Codex")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tool.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.C.text)
                    Text(state.healthMessage)
                        .font(.system(size: 9))
                        .foregroundStyle(DS.C.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { state.isActive },
                    set: { appState.setActive($0, for: tool) }
                ))
                .toggleStyle(.switch)
                .scaleEffect(0.72)
                .tint(DS.C.accent(tool))
            }

            HStack(spacing: DS.Space.sm) {
                pill(state.isActive ? "Active" : "Passive", color: state.isActive ? DS.C.green : DS.C.textMuted)
                pill(state.sourceHealth.label, color: healthColor(state.sourceHealth))
                pill(state.freshness.label, color: freshnessColor(state.freshness))
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("last fetch")
                        .dsLabel()
                    Text(state.lastSuccessfulFetch.map(relativeTime) ?? "never")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.C.textSub)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("next refresh")
                        .dsLabel()
                    Text(state.nextRefreshAt.map(countdown) ?? "not scheduled")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.C.textSub)
                }
            }

            HStack(spacing: DS.Space.sm) {
                Button(action: { appState.activate(tool) }) {
                    Label("Warm Now", systemImage: "bolt.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .foregroundStyle(.white)
                        .background(DS.C.accent(tool), in: RoundedRectangle(cornerRadius: DS.R.sm))
                }
                .buttonStyle(.plain)
                .disabled(state.isWarming)

                Button(action: { Task { await appState.refreshQuota(for: tool) } }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .foregroundStyle(DS.C.text)
                        .background(DS.C.surfaceHigh, in: RoundedRectangle(cornerRadius: DS.R.sm))
                }
                .buttonStyle(.plain)
                .disabled(state.isFetchingQuota)
            }
        }
        .padding(DS.Space.md)
        .background(DS.C.surface, in: RoundedRectangle(cornerRadius: DS.R.md))
        .overlay(RoundedRectangle(cornerRadius: DS.R.md).stroke(DS.C.border))
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack {
                Text("HISTORY").dsLabel()
                Spacer()
                Text("\(appState.history.count)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DS.C.textMuted)
            }
            if appState.history.isEmpty {
                Text("No events yet")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.C.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Space.lg)
            } else {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(appState.history.prefix(10)) { event in
                        HistoryRow(event: event)
                    }
                }
            }
        }
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.09), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.18)))
    }

    private func healthColor(_ health: SourceHealth) -> Color {
        switch health {
        case .healthy: return DS.C.green
        case .stale, .unknown: return DS.C.yellow
        case .rateLimited: return DS.C.yellow
        case .unavailable, .authFailure: return DS.C.red
        }
    }

    private func freshnessColor(_ freshness: QuotaFreshness) -> Color {
        switch freshness {
        case .fresh: return DS.C.green
        case .stale: return DS.C.yellow
        case .expired, .unknown: return DS.C.red
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }

    private func countdown(_ date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m"
    }
}

struct HistoryRow: View {
    let event: HistoryEvent

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.sm) {
            Text(time(event.timestamp))
                .font(DS.mono(9))
                .foregroundStyle(DS.C.textMuted)
                .frame(width: 45, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.C.text)
                Text(event.detail)
                    .font(.system(size: 9))
                    .foregroundStyle(DS.C.textMuted)
                    .lineLimit(2)
            }
        }
    }

    private var title: String {
        if let tool = event.tool {
            return "\(tool.displayName): \(event.title)"
        }
        return event.title
    }

    private func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
