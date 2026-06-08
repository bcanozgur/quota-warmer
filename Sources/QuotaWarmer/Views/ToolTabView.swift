import SwiftUI

struct ToolTabView: View {
    @ObservedObject var toolState: ToolState
    let onSetMode: (ToolMode) -> Void
    let onActivate: () -> Void
    let onRefresh: () -> Void

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            quotaList
            actions
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .background(DS.C.bg)
        .onReceive(ticker) { t in now = t }
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 9) {
                Image(toolState.tool == .claude ? "ClaudeCode" : "Codex")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .foregroundStyle(DS.C.text)
                Text(toolState.tool.shortName)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(DS.C.text)
            }
            Spacer()
            if toolState.isFetchingQuota {
                Image(systemName: "hourglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.C.textSub)
            }
            activeControl
        }
    }

    private var quotaList: some View {
        VStack(alignment: .leading, spacing: 22) {
            windowRow(
                title: "Session",
                metric: toolState.primaryMetric,
                resetAt: toolState.resetAt,
                windowDuration: toolState.tool.windowDuration
            )
            windowRow(
                title: "Weekly",
                metric: toolState.weeklyMetric,
                resetAt: toolState.weeklyMetric?.resetAt,
                windowDuration: toolState.tool.weeklyWindowDuration
            )
            if let error = toolState.errorMessage {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DS.C.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private func windowRow(title: String, metric: QuotaMetric?, resetAt: Date?, windowDuration: TimeInterval) -> some View {
        let quotaLeft = metric?.remainingFraction ?? 0
        let leftText = metric == nil ? "-- left" : "\(Int(quotaLeft * 100))% left"
        let pace = QuotaPace.compute(
            quotaLeft: quotaLeft,
            resetAt: resetAt,
            windowDuration: windowDuration,
            now: now,
            fallbackResetText: fallbackResetText(metric: metric)
        )
        return QuotaWindowRow(
            title: title,
            hasMetric: metric != nil,
            quotaLeft: quotaLeft,
            leftText: leftText,
            pace: pace,
            refreshing: toolState.isFetchingQuota
        )
    }

    private func fallbackResetText(metric: QuotaMetric?) -> String {
        guard metric != nil else {
            return toolState.isFetchingQuota ? "Updating..." : "No live quota"
        }
        if let metric, metric.isIdleFiveHourWindow {
            return "\(Int(metric.remainingFraction * 100))% left"
        }
        return freshnessFallback
    }

    private var freshnessFallback: String {
        switch toolState.freshness {
        case .fresh: return "Fresh"
        case .stale: return "Stale"
        case .expired: return "Expired data"
        case .unknown: return "No live quota"
        }
    }

    private var activeControl: some View {
        ToolModeMenu(mode: toolState.mode) { onSetMode($0) }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: onActivate) {
                Label("Warm", systemImage: "bolt.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(height: 32)
                    .padding(.horizontal, 14)
                    .foregroundStyle(.white)
                    .background(DS.C.accent(toolState.tool), in: Capsule())
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(toolState.isWarming)
            .accessibilityLabel(Text("Warm \(toolState.tool.shortName) now"))

            Button(action: onRefresh) {
                Label("Refresh", systemImage: toolState.isFetchingQuota ? "hourglass" : toolState.quotaBackoffActive ? "clock.arrow.circlepath" : "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(height: 32)
                    .padding(.horizontal, 14)
                    .foregroundStyle(DS.C.textSub)
                    .background(DS.C.surfaceHigh, in: Capsule())
                    .overlay(Capsule().stroke(DS.C.border, lineWidth: 1))
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(toolState.isFetchingQuota || toolState.quotaBackoffActive)
            .accessibilityLabel(Text("Refresh \(toolState.tool.shortName) quota now"))
        }
    }
}

struct LogEntryView: View {
    let entry: WarmupLog
    let accent: Color

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(Self.formatter.string(from: entry.timestamp))
                    .font(DS.mono(8))
                    .foregroundStyle(DS.C.textMuted)
                Text(entry.mode.uppercased())
                    .font(DS.mono(8, weight: .bold))
                    .foregroundStyle(accent)
                Text(entry.command)
                    .font(DS.mono(9))
                    .foregroundStyle(DS.C.textSub)
            }
            Text(entry.output)
                .font(DS.mono(9))
                .foregroundStyle(DS.C.textSub)
                .textSelection(.enabled)
                .lineLimit(6)
        }
        .padding(DS.Space.sm)
        .background(DS.C.bg, in: RoundedRectangle(cornerRadius: DS.R.sm))
        .overlay(RoundedRectangle(cornerRadius: DS.R.sm).stroke(DS.C.border))
    }
}

/// Off / Monitor / Auto-warm selector used in the tool tab and the main
/// provider rows. Rendered as a plain, always-visible button (a colored dot +
/// the mode label) that cycles through the three modes on click — deliberately
/// not a `Menu`, which renders unreliably inside the menu-bar popover.
struct ToolModeMenu: View {
    let mode: ToolMode
    var compact: Bool = false
    let onSelect: (ToolMode) -> Void

    var body: some View {
        Button(action: { onSelect(mode.next) }) {
            HStack(spacing: 5) {
                StatusDot(color: ToolModeMenu.color(mode), size: 7)
                Text(mode.label)
                    .font(.system(size: compact ? 10 : 12, weight: .semibold))
                    .foregroundStyle(DS.C.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, compact ? 9 : 12)
            .frame(height: compact ? 26 : 28)
            .background(DS.C.surface, in: Capsule())
            .overlay(Capsule().stroke(ToolModeMenu.color(mode).opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle())
        .help("Mode: \(mode.label). Click to cycle Off → Monitor → Auto-warm.")
        .accessibilityLabel(Text("Mode: \(mode.label). Activate to change."))
    }

    static func color(_ mode: ToolMode) -> Color {
        switch mode {
        case .off:      return DS.C.textMuted
        case .monitor:  return DS.C.blue
        case .autoWarm: return DS.C.green
        }
    }
}
