import SwiftUI

struct ToolTabView: View {
    @ObservedObject var toolState: ToolState
    let onSetActive: (Bool) -> Void
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
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .background(DS.C.bg)
        .onReceive(ticker) { t in now = t }
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 8) {
                Image(toolState.tool == .claude ? "ClaudeCode" : "Codex")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 21, height: 21)
                    .foregroundStyle(DS.C.text)
                Text(toolState.tool.shortDisplayName)
                    .font(.system(size: 18, weight: .semibold))
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
        VStack(alignment: .leading, spacing: 18) {
            ForEach(rows) { row in
                QuotaRowView(row: row, refreshing: toolState.isFetchingQuota)
            }
            if let error = toolState.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.C.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var rows: [QuotaDisplayRow] {
        [
            displayRow(title: "5h Window", metric: toolState.primaryMetric),
            displayRow(title: "Weekly", metric: toolState.weeklyMetric)
        ]
    }

    private func displayRow(title: String, metric: QuotaMetric?) -> QuotaDisplayRow {
        let percent = metric?.remainingFraction ?? 0
        let leading: String
        if metric == nil {
            leading = "0% left"
        } else {
            leading = "\(Int(percent * 100))% left"
        }

        return QuotaDisplayRow(
            title: title,
            progressFraction: percent,
            leadingValue: leading,
            resetText: resetText(for: metric, includeRemaining: title == "5h Window"),
            metricID: metric?.id
        )
    }

    private func resetText(for metric: QuotaMetric?, includeRemaining: Bool) -> String {
        guard let resetAt = metric?.resetAt else {
            return toolState.isFetchingQuota ? "Updating..." : freshnessFallback
        }
        let seconds = max(0, Int(resetAt.timeIntervalSince(now)))
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
        guard includeRemaining, let metric else { return "Resets in \(timeText)" }
        return "Resets in \(timeText) - \(Int(metric.remainingFraction * 100))% left"
    }

    private var freshnessFallback: String {
        switch toolState.freshness {
        case .fresh: return "Fresh"
        case .stale: return "Stale"
        case .expired: return "Expired"
        case .unknown: return "No data"
        }
    }

    private var activeControl: some View {
        Button(action: { onSetActive(!toolState.isActive) }) {
            HStack(spacing: 6) {
                Circle()
                    .fill(toolState.isActive ? DS.C.green : DS.C.red)
                    .frame(width: 6, height: 6)
                Text(toolState.isActive ? "Active" : "Passive")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(DS.C.text)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(DS.C.bg, in: RoundedRectangle(cornerRadius: DS.R.sm))
            .overlay(RoundedRectangle(cornerRadius: DS.R.sm).stroke(DS.C.border))
        }
        .buttonStyle(.plain)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: onActivate) {
                Label("Warm", systemImage: "bolt.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .frame(height: 30)
                    .padding(.horizontal, 12)
                    .foregroundStyle(.white)
                    .background(DS.C.accent(toolState.tool), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(toolState.isWarming)

            Button(action: onRefresh) {
                Label("Refresh", systemImage: toolState.isFetchingQuota ? "hourglass" : "arrow.clockwise")
                    .font(.system(size: 11.5, weight: .semibold))
                    .frame(height: 30)
                    .padding(.horizontal, 12)
                    .foregroundStyle(DS.C.text)
                    .background(DS.C.surfaceHigh, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(toolState.isFetchingQuota)
        }
    }
}

private struct QuotaDisplayRow: Identifiable {
    let id = UUID()
    let title: String
    let progressFraction: Double
    let leadingValue: String
    let resetText: String
    let metricID: UUID?
}

private struct QuotaRowView: View {
    let row: QuotaDisplayRow
    let refreshing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(row.title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(DS.C.text)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(DS.C.track)
                    Capsule()
                        .fill(DS.C.ink)
                        .frame(width: max(geometry.size.width * CGFloat(row.progressFraction), 0))
                    if refreshing {
                        Capsule()
                            .fill(.white.opacity(0.22))
                            .frame(width: geometry.size.width * 0.28)
                            .offset(x: geometry.size.width * 0.18)
                    }
                }
            }
            .frame(height: 9)

            HStack {
                Text(row.leadingValue)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DS.C.textSub)
                Spacer()
                Text(row.resetText)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DS.C.textSub)
            }
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

private extension ToolID {
    var shortDisplayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}
