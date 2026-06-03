import AppKit
import SwiftUI

struct ToolTabView: View {
    @ObservedObject var toolState: ToolState
    let onSetActive: (Bool) -> Void
    let onActivate: () -> Void
    let onRefresh: () -> Void

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            topActions
            quotaList
            creditsSection
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .background(DS.C.bg)
        .onReceive(ticker) { t in now = t }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text(toolState.tool.shortDisplayName)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(DS.C.text)
            Spacer()
            if toolState.isFetchingQuota {
                Image(systemName: "hourglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.C.textSub)
            }
            activeControl
        }
    }

    private var quotaList: some View {
        VStack(alignment: .leading, spacing: 26) {
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
            displayRow(title: "Session", metric: toolState.primaryMetric),
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
            resetText: resetText(for: metric),
            runoutText: runoutText(for: metric),
            metricID: metric?.id
        )
    }

    private func resetText(for metric: QuotaMetric?) -> String {
        guard let resetAt = metric?.resetAt else {
            return toolState.isFetchingQuota ? "Updating..." : freshnessFallback
        }
        let seconds = max(0, Int(resetAt.timeIntervalSince(now)))
        return "Resets in \(timeText(seconds))"
    }

    private func runoutText(for metric: QuotaMetric?) -> String {
        guard let metric else { return "Runs out --" }
        guard let resetAt = metric.resetAt else { return "Runs out --" }
        let remaining = max(0.01, min(metric.remainingFraction, 1))
        let window = max(1, resetAt.timeIntervalSince(now))
        let projected = Int(window * remaining)
        return "Runs out in \(timeText(projected))"
    }

    private func timeText(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
        return "\(seconds / 86_400)d \((seconds % 86_400) / 3600)h"
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
                Text(toolState.isActive ? "Active" : "Passive")
                    .font(.system(size: 18, weight: .medium))
            }
            .foregroundStyle(DS.C.text)
            .padding(.horizontal, 15)
            .frame(height: 42)
            .background(DS.C.surface, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(DS.C.border, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    private var topActions: some View {
        HStack(spacing: 10) {
            CapsuleButton(title: "Status", systemImage: "arrow.up.forward.square", action: openStatus)
            CapsuleButton(title: "Usage dashboard", systemImage: "arrow.up.forward.square", action: openDashboard)
            Spacer(minLength: 0)
        }
    }

    private var creditsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Credits")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(DS.C.text)
            Capsule()
                .fill(DS.C.track)
                .frame(height: 16)
            HStack {
                Text("No credit data")
                Spacer()
                Text("Quota checks only")
            }
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(DS.C.textSub)
            Divider()
                .padding(.top, 12)
            dashboardActionRow("Warm now", value: toolState.isWarming ? "Running" : "Ready", action: onActivate)
            dashboardActionRow("Quota update", value: toolState.isFetchingQuota ? "Updating" : nextUpdateText, action: onRefresh)
        }
        .padding(.top, 8)
    }

    private func dashboardActionRow(_ title: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(value)
            }
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(DS.C.textSub)
        }
        .buttonStyle(.plain)
    }

    private var nextUpdateText: String {
        guard let next = toolState.nextRefreshAt else { return "Manual" }
        let seconds = max(0, Int(next.timeIntervalSince(now)))
        return "Next update in \(timeText(seconds))"
    }

    private func openStatus() {
        let url = toolState.tool == .claude
            ? URL(string: "https://status.anthropic.com/")
            : URL(string: "https://status.openai.com/")
        if let url { NSWorkspace.shared.open(url) }
    }

    private func openDashboard() {
        let url = toolState.tool == .claude
            ? URL(string: "https://console.anthropic.com/settings/usage")
            : URL(string: "https://platform.openai.com/usage")
        if let url { NSWorkspace.shared.open(url) }
    }
}

private struct QuotaDisplayRow: Identifiable {
    let id = UUID()
    let title: String
    let progressFraction: Double
    let leadingValue: String
    let resetText: String
    let runoutText: String
    let metricID: UUID?
}

private struct QuotaRowView: View {
    let row: QuotaDisplayRow
    let refreshing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Text(row.title)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(DS.C.text)
                Circle()
                    .fill(DS.C.red)
                    .frame(width: 10, height: 10)
            }

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
            .frame(height: 16)

            HStack {
                Text(row.leadingValue)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(DS.C.textSub)
                Spacer()
                Text(row.resetText)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(DS.C.textSub)
            }
            HStack {
                Text(shortfallText)
                Spacer()
                Text(row.runoutText)
            }
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(DS.C.textSub)
        }
    }

    private var shortfallText: String {
        let used = max(0, 100 - Int(row.progressFraction * 100))
        return "\(used)% used"
    }
}

private struct CapsuleButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
            }
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(DS.C.text)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(DS.C.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(DS.C.border))
            .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
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

extension ToolID {
    var shortDisplayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}
