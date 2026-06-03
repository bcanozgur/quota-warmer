import SwiftUI

struct ToolTabView: View {
    @ObservedObject var toolState: ToolState
    let onActivate: () -> Void
    let onRefresh: () -> Void

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            header
            quotaList
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 48)
        .background(DS.C.bg)
        .onReceive(ticker) { t in now = t }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text(toolState.tool.shortDisplayName)
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(DS.C.text)
            Spacer()
            Text(planLabel)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(DS.C.text)
                .padding(.horizontal, 17)
                .frame(height: 42)
                .background(DS.C.bg, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(DS.C.border, lineWidth: 2))
        }
    }

    private var quotaList: some View {
        VStack(alignment: .leading, spacing: 32) {
            ForEach(rows) { row in
                QuotaRowView(row: row)
            }
            if let error = toolState.errorMessage {
                Text(error)
                    .font(.system(size: 16))
                    .foregroundStyle(DS.C.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var rows: [QuotaDisplayRow] {
        var output: [QuotaDisplayRow] = [
            displayRow(title: "Session", metric: toolState.primaryMetric),
            displayRow(title: "Weekly", metric: toolState.weeklyMetric)
        ]

        let extras = normalizedExtras
        if toolState.tool == .codex {
            output.append(displayRow(title: "Reviews", metric: extras.first { $0.name.localizedCaseInsensitiveContains("review") }))
            output.append(displayRow(title: "Credits", metric: extras.first { $0.name.localizedCaseInsensitiveContains("credit") }, showsRawValue: true))
        } else {
            output.append(displayRow(title: "Sonnet", metric: extras.first { $0.name.localizedCaseInsensitiveContains("sonnet") }))
            output.append(displayRow(title: "Opus", metric: extras.first { $0.name.localizedCaseInsensitiveContains("opus") }))
        }

        let namedIDs = Set(output.compactMap { $0.metricID })
        let additional = extras
            .filter { !namedIDs.contains($0.id) }
            .prefix(2)
            .map { displayRow(title: $0.name.displayTitle, metric: $0) }
        output.append(contentsOf: additional)

        return output
    }

    private var normalizedExtras: [QuotaMetric] {
        toolState.quotaSnapshot?.extras ?? []
    }

    private func displayRow(title: String, metric: QuotaMetric?, showsRawValue: Bool = false) -> QuotaDisplayRow {
        let percent = metric?.clampedUsed ?? 0
        let leading: String
        if showsRawValue, let detail = metric?.detail {
            leading = detail.components(separatedBy: "/").first?.trimmingCharacters(in: .whitespaces) ?? "\(Int(percent * 100))%"
        } else if metric == nil {
            leading = "0%"
        } else {
            leading = "\(Int(percent * 100))%"
        }

        return QuotaDisplayRow(
            title: title,
            usedFraction: percent,
            leadingValue: leading,
            resetText: resetText(for: metric),
            metricID: metric?.id
        )
    }

    private func resetText(for metric: QuotaMetric?) -> String {
        guard let resetAt = metric?.resetAt else {
            return toolState.isFetchingQuota ? "Updating..." : freshnessFallback
        }
        let seconds = max(0, Int(resetAt.timeIntervalSince(now)))
        if seconds < 60 { return "Resets in \(seconds)s" }
        if seconds < 3600 { return "Resets in \(seconds / 60)m" }
        if seconds < 86_400 {
            return "Resets in \(seconds / 3600)h \((seconds % 3600) / 60)m"
        }
        return "Resets in \(seconds / 86_400)d \((seconds % 86_400) / 3600)h"
    }

    private var freshnessFallback: String {
        switch toolState.freshness {
        case .fresh: return "Fresh"
        case .stale: return "Stale"
        case .expired: return "Expired"
        case .unknown: return "No data"
        }
    }

    private var planLabel: String {
        if toolState.authStatus == .available { return "Pro" }
        if toolState.authStatus == .missing { return "Auth" }
        return toolState.isActive ? "Active" : "Passive"
    }
}

private struct QuotaDisplayRow: Identifiable {
    let id = UUID()
    let title: String
    let usedFraction: Double
    let leadingValue: String
    let resetText: String
    let metricID: UUID?
}

private struct QuotaRowView: View {
    let row: QuotaDisplayRow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(row.title)
                .font(.system(size: 29, weight: .semibold))
                .foregroundStyle(DS.C.text)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(DS.C.track)
                    Capsule()
                        .fill(DS.C.ink)
                        .frame(width: max(geometry.size.width * CGFloat(row.usedFraction), 0))
                }
            }
            .frame(height: 24)

            HStack {
                Text(row.leadingValue)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(DS.C.textSub)
                Spacer()
                Text(row.resetText)
                    .font(.system(size: 24, weight: .regular))
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

private extension String {
    var displayTitle: String {
        replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }
}
