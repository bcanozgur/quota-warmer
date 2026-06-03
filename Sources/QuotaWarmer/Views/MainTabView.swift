import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var historyExpanded = true

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                header
                providerList
                historySection
            }
            .padding(.horizontal, 24)
            .padding(.top, 26)
            .padding(.bottom, 18)
        }
        .background(DS.C.bg)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("QuotaWarmer")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(DS.C.text)
                Text("Choose a tool to keep warm.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.C.textMuted)
            }
            Spacer()
            Toggle("", isOn: $appState.globalPassive)
                .toggleStyle(.switch)
                .scaleEffect(0.70)
                .tint(DS.C.red)
        }
    }

    private var providerList: some View {
        VStack(spacing: 0) {
            ForEach(ToolID.allCases) { tool in
                providerRow(tool)
                if tool != ToolID.allCases.last {
                    Divider()
                        .padding(.leading, 42)
                }
            }
        }
        .padding(.vertical, 2)
        .background(DS.C.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DS.C.border))
    }

    private func providerRow(_ tool: ToolID) -> some View {
        let state = appState.state(for: tool)
        return HStack(alignment: .top, spacing: 14) {
            Image(tool == .claude ? "ClaudeCode" : "Codex")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 22, height: 22)
                .foregroundStyle(DS.C.text)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(tool.shortDisplayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.C.text)
                    Circle()
                        .fill(state.isActive ? DS.C.green : DS.C.red)
                        .frame(width: 5.5, height: 5.5)
                    Text(providerStatus(state))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(state.sourceHealth == .authFailure ? DS.C.red : DS.C.textMuted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                quotaLine("5h", metric: state.primaryMetric, refreshing: state.isFetchingQuota)
                quotaLine("Week", metric: state.weeklyMetric, refreshing: state.isFetchingQuota)
            }

            VStack(spacing: 7) {
                Toggle("", isOn: Binding(
                    get: { state.isActive },
                    set: { appState.setActive($0, for: tool) }
                ))
                .toggleStyle(.switch)
                .scaleEffect(0.68)
                .tint(DS.C.accent(tool))

                Button(action: { Task { await appState.refreshQuota(for: tool) } }) {
                    Image(systemName: state.isFetchingQuota ? "hourglass" : "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.C.textSub)
                        .frame(width: 26, height: 24)
                        .background(DS.C.bg, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: DS.R.sm).stroke(DS.C.border))
                }
                .buttonStyle(.plain)
                .disabled(state.isFetchingQuota)
            }
            .frame(width: 42)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button(action: { historyExpanded.toggle() }) {
                HStack {
                    Text("History").font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Text("\(appState.history.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.C.textMuted)
                    Image(systemName: historyExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DS.C.textMuted)
                }
            }
            .buttonStyle(.plain)
            if historyExpanded {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(DS.C.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DS.C.border))
    }

    private func quotaLine(_ label: String, metric: QuotaMetric?, refreshing: Bool) -> some View {
        let remaining = metric?.remainingFraction ?? 0
        return HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(DS.C.textMuted)
                .frame(width: 34, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(DS.C.track)
                    Capsule()
                        .fill(DS.C.ink)
                        .frame(width: geometry.size.width * CGFloat(remaining))
                    if refreshing {
                        Capsule()
                            .fill(.white.opacity(0.22))
                            .frame(width: geometry.size.width * 0.25)
                            .offset(x: geometry.size.width * 0.25)
                    }
                }
            }
            .frame(height: 7)
            Text(metric.map { "\(Int($0.remainingFraction * 100))%" } ?? "--")
                .font(DS.mono(10.5, weight: .medium))
                .foregroundStyle(DS.C.textSub)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private func providerStatus(_ state: ToolState) -> String {
        if state.isFetchingQuota { return "updating" }
        if state.isWarming { return "warming" }
        if let error = state.errorMessage, !error.isEmpty { return error }
        if let last = state.lastSuccessfulFetch { return "checked \(relativeTime(last))" }
        return state.isActive ? "active" : "passive"
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
}

struct HistoryRow: View {
    let event: HistoryEvent

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.sm) {
            Text(time(event.timestamp))
                .font(DS.mono(9.5))
                .foregroundStyle(DS.C.textMuted)
                .frame(width: 45, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(DS.C.text)
                Text(event.detail)
                    .font(.system(size: 9.5))
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
