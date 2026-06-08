import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var historyExpanded = true

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                header
                if !outcomeTools.isEmpty { statusCard }
                providerList
                historySection
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 16)
        }
        .background(DS.C.bg)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("QuotaWarmer")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(DS.C.text)
                Text("Keep your quota windows warm.")
                    .font(.system(size: 12, weight: .medium))
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
            StatusBadge(text: paused ? "Paused" : "Active", color: stateColor)

            IconButton(
                systemName: paused ? "play.fill" : "pause.fill",
                help: helpText,
                tint: paused ? DS.C.green : DS.C.red,
                border: (paused ? DS.C.green : DS.C.red).opacity(0.30),
                size: 26
            ) { appState.globalPassive.toggle() }
        }
        .help(helpText)
    }

    private var providerList: some View {
        VStack(spacing: 0) {
            ForEach(ToolID.allCases) { tool in
                providerRow(tool)
                if tool != ToolID.allCases.last {
                    Rectangle()
                        .fill(DS.C.border)
                        .frame(height: 1)
                        .padding(.vertical, 18)
                }
            }
        }
    }

    private func providerRow(_ tool: ToolID) -> some View {
        let state = appState.state(for: tool)
        return VStack(alignment: .leading, spacing: 16) {
            // Tool name on the left, the same mode / refresh / pin controls on
            // the right (where the reference shows the plan badge).
            HStack(spacing: 8) {
                Text(tool.shortName)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(DS.C.text)
                Spacer(minLength: 6)
                ToolModeMenu(mode: state.mode, compact: true) { appState.setMode($0, for: tool) }
                    .fixedSize()
                IconButton(
                    systemName: state.isFetchingQuota ? "hourglass" : state.quotaBackoffActive ? "clock.arrow.circlepath" : "arrow.clockwise",
                    help: "Refresh \(tool.shortName) quota now",
                    size: 26,
                    isDisabled: state.isFetchingQuota || state.quotaBackoffActive
                ) { Task { await appState.refreshQuota(for: tool) } }
                menuBarPin(tool, state)
            }

            if let issue = providerIssue(state) {
                Text(issue)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.C.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            windowRow(state, title: "Session", metric: state.primaryMetric,
                      resetAt: state.resetAt, windowDuration: tool.windowDuration)
            windowRow(state, title: "Weekly", metric: state.weeklyMetric,
                      resetAt: state.weeklyMetric?.resetAt, windowDuration: tool.weeklyWindowDuration)
        }
    }

    private func windowRow(_ state: ToolState, title: String, metric: QuotaMetric?, resetAt: Date?, windowDuration: TimeInterval) -> some View {
        let quotaLeft = metric?.remainingFraction ?? 0
        let leftText = metric == nil ? "-- left" : "\(Int(quotaLeft * 100))% left"
        let pace = QuotaPace.compute(
            quotaLeft: quotaLeft,
            resetAt: resetAt,
            windowDuration: windowDuration,
            now: Date(),
            fallbackResetText: fallbackResetText(state, metric: metric)
        )
        return QuotaWindowRow(
            title: title,
            hasMetric: metric != nil,
            quotaLeft: quotaLeft,
            leftText: leftText,
            pace: pace,
            refreshing: state.isFetchingQuota
        )
    }

    private func fallbackResetText(_ state: ToolState, metric: QuotaMetric?) -> String {
        guard metric != nil else {
            return state.isFetchingQuota ? "Updating..." : "No live quota"
        }
        if let metric, metric.isIdleFiveHourWindow {
            return "\(Int(metric.remainingFraction * 100))% left"
        }
        switch state.freshness {
        case .fresh: return "Fresh"
        case .stale: return "Stale"
        case .expired: return "Expired data"
        case .unknown: return "No live quota"
        }
    }

    private func providerIssue(_ state: ToolState) -> String? {
        if state.sourceHealth == .authFailure, let msg = state.errorMessage, !msg.isEmpty {
            return msg
        }
        if let retryAt = state.authRetryScheduledAt, retryAt > Date() {
            return "Re-checking auth at \(shortClock(retryAt))"
        }
        return nil
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
        .buttonStyle(PressableButtonStyle())
        .help(state.menuBarVisible ? "Showing in menu bar — click to hide" : "Hidden from menu bar — click to show")
        .accessibilityLabel(Text(state.menuBarVisible ? "Hide \(tool.shortName) from menu bar" : "Show \(tool.shortName) in menu bar"))
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: { historyExpanded.toggle() }) {
                HStack(spacing: 6) {
                    Text("History").dsSectionLabel()
                    Spacer()
                    Text("\(appState.history.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.C.textMuted)
                    Image(systemName: historyExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DS.C.textMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(Text(historyExpanded ? "Collapse history" : "Expand history"))
            if historyExpanded {
                if appState.history.isEmpty {
                    Text("No events yet")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.C.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.Space.lg)
                } else {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(appState.history.prefix(10)) { event in
                            HistoryRow(event: event)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .dsCard()
    }

    // MARK: - Last warm-up status card ("did it actually work?")

    private var outcomeTools: [ToolID] {
        // Only show a row once an actual warm-up outcome exists. Mode is already
        // visible in each provider row (its colored dot + status text), so the
        // Auto-warm state no longer adds a card here — that previously made the
        // panel grow/shrink on every mode toggle and jolt the scroll position.
        ToolID.allCases.filter { tool in
            if case .none = appState.state(for: tool).lastWarmupOutcome { return false }
            return true
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Window Status")
                .dsSectionLabel()
            ForEach(outcomeTools) { tool in
                outcomeRow(tool)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    private func outcomeRow(_ tool: ToolID) -> some View {
        let state = appState.state(for: tool)
        let info = outcomeInfo(state.lastWarmupOutcome, mode: state.mode)
        return HStack(alignment: .top, spacing: 9) {
            StatusDot(color: info.color, size: 7)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.shortName)
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
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(DS.C.accent(tool), in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(state.isWarming)
                .accessibilityLabel(Text("Warm \(tool.shortName) now"))
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
            return "\(tool.shortName): \(event.title)"
        }
        return event.title
    }

    private func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
