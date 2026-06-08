import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var historyExpanded = true

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 13) {
                header
                if !outcomeTools.isEmpty { statusCard }
                providerList
                historySection
            }
            .padding(.horizontal, 17)
            .padding(.top, 17)
            .padding(.bottom, 14)
        }
        .background(DS.C.bg)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("QuotaWarmer")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(DS.C.text)
                Text("Choose a tool to keep warm.")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DS.C.textMuted)
            }
            Spacer()
            automationControl
        }
    }

    private var automationControl: some View {
        let paused = appState.globalPassive
        let helpText = paused ? "Resume automatic warmups" : "Pause all automatic warmups"
        let stateColor = paused ? DS.C.red : DS.C.green

        return HStack(spacing: 7) {
            HStack(spacing: 5) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 6, height: 6)
                Text(paused ? "Paused" : "Active")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.C.textSub)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(stateColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(stateColor.opacity(0.28), lineWidth: 1)
            )

            Button(action: { appState.globalPassive.toggle() }) {
                Image(systemName: paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(paused ? DS.C.green : DS.C.red)
                    .frame(width: 32, height: 28)
                    .background(DS.C.surfaceHigh, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(paused ? DS.C.green.opacity(0.35) : DS.C.red.opacity(0.30), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help(helpText)
            .accessibilityLabel(Text(helpText))
        }
        .help(helpText)
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
        .background(DS.C.surface, in: RoundedRectangle(cornerRadius: DS.R.md))
        .overlay(RoundedRectangle(cornerRadius: DS.R.md).stroke(DS.C.border))
    }

    private func providerRow(_ tool: ToolID) -> some View {
        let state = appState.state(for: tool)
        return HStack(alignment: .top, spacing: 12) {
            Image(tool == .claude ? "ClaudeCode" : "Codex")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(DS.C.text)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 8.5) {
                HStack(spacing: 6) {
                    Text(tool.displayName)
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(DS.C.text)
                    Circle()
                        .fill(ToolModeMenu.color(state.mode))
                        .frame(width: 5.5, height: 5.5)
                    Text(providerStatus(state))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(state.sourceHealth == .authFailure ? DS.C.red : DS.C.textMuted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    menuBarPin(tool, state)
                }

                quotaLine("5h", metric: state.primaryMetric, refreshing: state.isFetchingQuota)
                quotaLine("Week", metric: state.weeklyMetric, refreshing: state.isFetchingQuota)
                if let weeklyText = weeklyResetText(state) {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.system(size: 8.5, weight: .semibold))
                        Text(weeklyText)
                            .font(.system(size: 9.5, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(DS.C.textMuted)
                    .help(weeklyResetHelp(state) ?? weeklyText)
                }
            }

            VStack(spacing: 7) {
                ToolModeMenu(mode: state.mode, compact: true) { appState.setMode($0, for: tool) }

                Button(action: { Task { await appState.refreshQuota(for: tool) } }) {
                    Image(systemName: state.isFetchingQuota ? "hourglass" : state.quotaBackoffActive ? "clock.arrow.circlepath" : "arrow.clockwise")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(DS.C.textSub)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(DS.C.bg, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: DS.R.sm).stroke(DS.C.border))
                }
                .buttonStyle(.plain)
                .disabled(state.isFetchingQuota || state.quotaBackoffActive)
            }
            .frame(width: 84)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
    }

    /// Minimal pin toggle: shows/hides this tool's quota in the menu bar,
    /// independent of whether warmup is active.
    private func menuBarPin(_ tool: ToolID, _ state: ToolState) -> some View {
        Button(action: { appState.setMenuBarVisible(tool, !state.menuBarVisible) }) {
            Image(systemName: "menubar.rectangle")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(state.menuBarVisible ? DS.C.accent(tool) : DS.C.textMuted)
                .opacity(state.menuBarVisible ? 1.0 : 0.45)
        }
        .buttonStyle(.plain)
        .help(state.menuBarVisible ? "Showing in menu bar — click to hide" : "Hidden from menu bar — click to show")
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button(action: { historyExpanded.toggle() }) {
                HStack {
                    Text("History").font(.system(size: 13, weight: .bold))
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
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .background(DS.C.surface, in: RoundedRectangle(cornerRadius: DS.R.md))
        .overlay(RoundedRectangle(cornerRadius: DS.R.md).stroke(DS.C.border))
    }

    // MARK: - Last warm-up status card ("did it actually work?")

    private var outcomeTools: [ToolID] {
        ToolID.allCases.filter { tool in
            let state = appState.state(for: tool)
            // Show a row once a warm-up has happened, or proactively for any
            // tool set to Auto-warm so the mode's effect is visible immediately.
            if case .none = state.lastWarmupOutcome { return state.mode == .autoWarm }
            return true
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("WINDOW STATUS")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(DS.C.textMuted)
            ForEach(outcomeTools) { tool in
                outcomeRow(tool)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.C.surface, in: RoundedRectangle(cornerRadius: DS.R.md))
        .overlay(RoundedRectangle(cornerRadius: DS.R.md).stroke(DS.C.border))
    }

    private func outcomeRow(_ tool: ToolID) -> some View {
        let state = appState.state(for: tool)
        let info = outcomeInfo(state.lastWarmupOutcome, mode: state.mode)
        return HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(info.color)
                .frame(width: 7, height: 7)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.displayName)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(DS.C.text)
                Text(info.message)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(DS.C.textSub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if info.showWarm {
                Button(action: { appState.activate(tool) }) {
                    Text("Warm")
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(DS.C.accent(tool), in: RoundedRectangle(cornerRadius: DS.R.sm))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(state.isWarming)
            }
        }
    }

    private func outcomeInfo(_ outcome: WarmupOutcome, mode: ToolMode) -> (color: Color, message: String, showWarm: Bool) {
        switch outcome {
        case .none:
            if mode == .autoWarm {
                return (DS.C.green, "Auto-warm on — the next fresh window will be claimed automatically.", false)
            }
            return (DS.C.textMuted, "No warm-up yet.", false)
        case .pending:
            return (DS.C.yellow, "Warm-up sent — verifying the window opened…", false)
        case .confirmed(let at, let resetAt):
            var message = "Window claimed at \(shortClock(at))"
            if let resetAt, resetAt > Date() {
                let seconds = Int(resetAt.timeIntervalSinceNow)
                message += " · resets in \(seconds / 3600)h \((seconds % 3600) / 60)m"
            }
            return (DS.C.green, message, false)
        case .unverified:
            return (DS.C.yellow, "Sent, but the window hasn't shown up in quota yet. Try warming again.", true)
        case .failed(_, let reason):
            return (DS.C.red, "Warm-up failed: \(reason)", true)
        }
    }

    private func quotaLine(_ label: String, metric: QuotaMetric?, refreshing: Bool) -> some View {
        let remaining = metric?.remainingFraction ?? 0
        return HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
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
            .frame(height: 8)
            Text(metric.map { "\(Int($0.remainingFraction * 100))%" } ?? "--")
                .font(DS.mono(10.5, weight: .semibold))
                .foregroundStyle(DS.C.textSub)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private func providerStatus(_ state: ToolState) -> String {
        if state.isFetchingQuota { return "updating" }
        if state.isWarming { return "warming" }
        if let retryAt = state.authRetryScheduledAt, retryAt > Date() {
            return "recheck at \(shortClock(retryAt))"
        }
        if let error = state.errorMessage, !error.isEmpty { return error }
        if let last = state.lastSuccessfulFetch { return "checked \(relativeTime(last))" }
        return state.mode.label.lowercased()
    }

    private func weeklyResetText(_ state: ToolState) -> String? {
        guard let resetAt = state.weeklyMetric?.resetAt else { return nil }
        let seconds = max(0, Int(resetAt.timeIntervalSinceNow))
        let timeText: String
        if seconds < 60 {
            timeText = "\(seconds)s"
        } else if seconds < 3600 {
            timeText = "\(seconds / 60)m"
        } else if seconds < 86_400 {
            timeText = "\(seconds / 3600)h \((seconds % 3600) / 60)m"
        } else {
            timeText = "\(seconds / 86_400)d \((seconds % 86_400) / 3600)h"
        }
        return "Weekly resets in \(timeText) · \(Self.weekdayDateFormatter.string(from: resetAt))"
    }

    private static let weekdayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter
    }()

    private func weeklyResetHelp(_ state: ToolState) -> String? {
        guard let resetAt = state.weeklyMetric?.resetAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Weekly window resets on \(formatter.string(from: resetAt))"
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }

    private func shortClock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct HistoryRow: View {
    let event: HistoryEvent

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.sm) {
            Text(time(event.timestamp))
                .font(DS.mono(10))
                .foregroundStyle(DS.C.textMuted)
                .frame(width: 45, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.C.text)
                Text(event.detail)
                    .font(.system(size: 10))
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
