import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var historyExpanded = false
    // Session-only display state — never persisted, so every popover open
    // starts with both provider sections expanded (empty = nothing collapsed).
    @State private var collapsedTools: Set<ToolID> = []

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
        VStack(spacing: 12) {
            ForEach(ToolID.allCases) { tool in
                providerRow(tool)
            }
        }
    }

    private func providerRow(_ tool: ToolID) -> some View {
        let state = appState.state(for: tool)
        let collapsed = collapsedTools.contains(tool)
        return VStack(alignment: .leading, spacing: collapsed ? 0 : 16) {
            // Tool name on the left, the same mode / refresh / pin controls on
            // the right (where the reference shows the plan badge).
            HStack(spacing: 8) {
                Button(action: { toggleCollapsed(tool) }) {
                    HStack(spacing: 6) {
                        Text(tool.shortName)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(DS.C.text)
                        Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DS.C.textMuted)
                    }
                    // The label's natural bounds are just the glyphs — pad the
                    // hit area out to a comfortably tappable rectangle instead
                    // of relying on precise glyph-edge hits.
                    .padding(.vertical, 6)
                    .padding(.trailing, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(Text(collapsed ? "Expand \(tool.shortName) section" : "Collapse \(tool.shortName) section"))
                Spacer(minLength: 6)
                ToolModeMenu(mode: state.mode, compact: true) { appState.setMode($0, for: tool) }
                    .fixedSize()
                IconButton(
                    systemName: state.isFetchingQuota ? "hourglass" : state.quotaBackoffActive ? "clock.arrow.circlepath" : "arrow.clockwise",
                    help: "Refresh \(tool.shortName) quota now",
                    size: 26,
                    // Only an in-flight fetch disables Refresh. Disabling it
                    // during a rate-limit backoff made the control dead for the
                    // whole retry window — which is exactly when the user wants
                    // to retry. `refreshQuotaManually` forces through it.
                    isDisabled: state.isFetchingQuota
                ) { Task { await appState.refreshQuotaManually(for: tool) } }
                menuBarPin(tool, state)
            }

            if !collapsed {
                if let issue = providerIssue(state) {
                    Text(issue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.C.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                windowRow(state, title: "Session", metric: state.primaryMetric,
                          resetAt: state.resetAt, windowDuration: tool.windowDuration,
                          settling: state.sessionSettling)
                windowRow(state, title: "Weekly", metric: state.weeklyMetric,
                          resetAt: state.weeklyMetric?.resetAt, windowDuration: tool.weeklyWindowDuration)
            }
        }
        .padding(.horizontal, collapsed ? 12 : 14)
        .padding(.vertical, collapsed ? 9 : 13)
        .dsCard()
    }

    private func toggleCollapsed(_ tool: ToolID) {
        if collapsedTools.contains(tool) {
            collapsedTools.remove(tool)
        } else {
            collapsedTools.insert(tool)
        }
    }

    private func windowRow(_ state: ToolState, title: String, metric: QuotaMetric?, resetAt: Date?, windowDuration: TimeInterval, settling: Bool = false) -> some View {
        let quotaLeft = metric?.remainingFraction ?? 0
        // A just-opened window the provider transiently reports as near-empty:
        // show the reset countdown but neither the bogus "0% left" nor the
        // "behind pace / runs out" alarm until the real number settles.
        let settlingActive = settling && metric != nil
        // An idle (not-yet-started) 5h window only carries a sliding "if you
        // started now" projection, not a real boundary — rendering it as
        // "Resets in 4h 56m" makes a window that hasn't opened look active. Drop
        // the projected reset so the row falls back to "Not started yet".
        let effectiveReset = metric?.isIdleFiveHourWindow == true ? nil : resetAt
        let leftText = ToolStatusCopy.quotaLeftText(for: state, metric: metric, settling: settlingActive)
        let pace = QuotaPace.compute(
            quotaLeft: settlingActive ? 1 : quotaLeft,
            resetAt: effectiveReset,
            windowDuration: windowDuration,
            now: Date(),
            fallbackResetText: fallbackResetText(state, metric: metric)
        )
        return QuotaWindowRow(
            title: title,
            hasMetric: metric != nil,
            quotaLeft: settlingActive ? (pace.timeLeftFraction ?? quotaLeft) : quotaLeft,
            leftText: leftText,
            pace: pace,
            refreshing: state.isFetchingQuota || settlingActive,
            statusColor: ToolStatusCopy.rowStatusColor(for: state, hasMetric: metric != nil)
        )
    }

    private func fallbackResetText(_ state: ToolState, metric: QuotaMetric?) -> String {
        ToolStatusCopy.resetFallback(for: state, metric: metric)
    }

    private func providerIssue(_ state: ToolState) -> String? {
        ToolStatusCopy.providerIssue(for: state)
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
        case .unverified(let sentAt, _):
            return (
                DS.C.yellow,
                "Command sent at \(shortClock(sentAt)), but live quota did not confirm that the window opened.",
                true
            )
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
