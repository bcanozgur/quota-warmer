import Charts
import SwiftUI

/// Usage over time: how full each 5-hour window got, the session/weekly
/// trend, daily tokens from the local CLI logs and the busy hours — for one
/// account, or for every account at once ("All"). Quota samples are recorded
/// on every successful poll (`UsageHistoryStore`); token data comes from each
/// account's `tokenUsageSummary`.
struct HistoryTabView: View {
    static let allKey = "all"

    @EnvironmentObject var appState: AppState
    @AppStorage("historyRange") private var rangeRaw = HistoryRange.week.rawValue
    @AppStorage("historyProvider") private var providerKey = HistoryTabView.allKey
    @State private var samplesByKey: [String: [QuotaSample]] = [:]
    @State private var loaded = false

    private var range: HistoryRange { HistoryRange(rawValue: rangeRaw) ?? .week }

    /// nil = All.
    private var selectedProvider: ProviderID? {
        appState.providers.first { $0.storageKey == providerKey }
    }

    private var selectedProviders: [ProviderID] {
        selectedProvider.map { [$0] } ?? appState.providers
    }

    private var series: [HistorySeries] {
        selectedProviders.map { tool in
            let state = appState.state(for: tool)
            return HistorySeries(
                tool: tool,
                samples: samplesByKey[tool.storageKey] ?? [],
                tokens: state.tokenUsageSummary,
                isMonitored: state.isMonitored,
                isFetchingTokens: state.isFetchingTokenUsage
            )
        }
    }

    /// Reloads when the selection, range or any selected account's latest
    /// reading changes.
    private var loadKey: String {
        let fetches = selectedProviders
            .map { appState.state(for: $0).lastSuccessfulFetch?.timeIntervalSince1970 ?? 0 }
            .map { String(Int($0)) }
            .joined(separator: ",")
        return "\(providerKey)|\(range.rawValue)|\(fetches)"
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: DS.Page.spacing) {
                PanelHeader(title: "History") { rangePicker }
                providerPicker
                HistoryContent(
                    series: series,
                    combined: selectedProvider == nil,
                    range: range,
                    loaded: loaded
                )
            }
            .padding(.horizontal, DS.Page.side)
            .padding(.top, DS.Page.top)
            .padding(.bottom, DS.Page.bottom)
            // Size the panel to show every chart; the scroll view only kicks in
            // when the screen is too short for the whole tab.
            .reportsPanelHeight()
        }
        .background(DS.C.bg)
        .task(id: loadKey) {
            let since = Date().addingTimeInterval(-range.interval)
            var loadedSamples: [String: [QuotaSample]] = [:]
            for tool in selectedProviders {
                loadedSamples[tool.storageKey] = await UsageHistoryStore.shared.samples(for: tool, since: since)
            }
            samplesByKey = loadedSamples
            loaded = true
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 2) {
            ForEach(HistoryRange.allCases) { option in
                let selected = option == range
                Button(action: { rangeRaw = option.rawValue }) {
                    Text(option.label)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(selected ? DS.C.surface : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(selected ? DS.C.border : .clear, lineWidth: 1))
                        .foregroundStyle(selected ? DS.C.text : DS.C.textMuted)
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(Text("Show \(option.accessibilityLabel)"))
            }
        }
        .padding(2)
        .background(DS.C.surfaceHigh, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var providerPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(title: "All", selected: selectedProvider == nil, color: DS.C.ink) {
                    providerKey = Self.allKey
                } icon: {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 10, weight: .semibold))
                }
                ForEach(appState.providers) { tool in
                    chip(title: tool.shortName, selected: tool == selectedProvider, color: DS.C.accent(tool)) {
                        providerKey = tool.storageKey
                    } icon: {
                        Image(tool.kind.glyphAssetName)
                            .resizable()
                            .renderingMode(.template)
                            .scaledToFit()
                            .frame(width: 12, height: 12)
                    }
                }
            }
        }
    }

    private func chip<Icon: View>(
        title: String,
        selected: Bool,
        color: Color,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                icon()
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .foregroundStyle(selected ? DS.C.bg : DS.C.textSub)
            .background(selected ? color : DS.C.surfaceHigh, in: Capsule())
            .overlay(Capsule().stroke(selected ? .clear : DS.C.border, lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle())
    }
}

/// A window bar in the "Peak per 5h window" chart.
private struct WindowBar: Identifiable {
    let id: String
    let window: QuotaWindowSummary
    /// The window's span cut to the chart's range, so an open window (whose
    /// reset is still ahead) or one that began before the range stays inside.
    let start: Date
    let end: Date
    let color: Color
}

/// One account's data for the History charts.
struct HistorySeries: Identifiable {
    let tool: ProviderID
    let samples: [QuotaSample]
    let tokens: TokenUsageSummary?
    let isMonitored: Bool
    let isFetchingTokens: Bool

    var id: String { tool.storageKey }

    var windows: [QuotaWindowSummary] {
        UsageHistory.windows(from: samples, duration: tool.windowDuration)
    }
}

enum HistoryRange: String, CaseIterable, Identifiable {
    case day, week, month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: return "24h"
        case .week: return "7d"
        case .month: return "30d"
        }
    }

    /// "last 7 days", for card titles.
    var longLabel: String {
        switch self {
        case .day: return "last 24 hours"
        case .week: return "last 7 days"
        case .month: return "last 30 days"
        }
    }

    var accessibilityLabel: String { longLabel }

    var interval: TimeInterval {
        switch self {
        case .day: return 24 * 3600
        case .week: return 7 * 24 * 3600
        case .month: return 30 * 24 * 3600
        }
    }

    /// Days of local-log token bars to show.
    var dayCount: Int {
        switch self {
        case .day, .week: return 7
        case .month: return 30
        }
    }
}

/// The stat row and charts for one or more accounts. `combined` draws each
/// account in its brand color on shared charts; a single account keeps the
/// usage-level colors.
private struct HistoryContent: View {
    let series: [HistorySeries]
    let combined: Bool
    let range: HistoryRange
    let loaded: Bool

    @AppStorage(QuotaDisplay.colorfulBarsKey) private var colorfulBars = true

    var body: some View {
        let windowsByAccount = series.map { ($0, $0.windows) }
        let allWindows = windowsByAccount.flatMap(\.1)
        let allSamples = series.flatMap(\.samples)
        let stats = UsageHistory.stats(samples: allSamples, windows: allWindows)
        // Combined: the account closest to its weekly cap is what matters.
        let weekly = combined
            ? series.compactMap { UsageHistory.stats(samples: $0.samples, windows: []).latestWeekly }.max()
            : stats.latestWeekly
        VStack(alignment: .leading, spacing: DS.Page.spacing) {
            statRow(stats, weekly: weekly)
            dailyTokensCard
            heatmapCard
            if loaded && allSamples.isEmpty {
                emptyCard
            } else {
                usageCard
                windowCard(windowsByAccount)
            }
        }
    }

    // MARK: - Stats

    private func statRow(_ stats: UsageHistoryStats, weekly: Double?) -> some View {
        let scope = combined ? " across all accounts" : ""
        return HStack(spacing: 8) {
            statTile("Windows", value: "\(stats.windowCount)",
                     info: "How many 5-hour quota windows were opened\(scope) in this range. A window starts with your first message (or a warm-up) and resets 5 hours later.")
            statTile("Avg peak", value: stats.averagePeak.map(percent) ?? "–",
                     info: "On average, how full each window\(scope) got before it reset. Low means quota was left unused; high means you used most of it.")
            statTile("Hit limit", value: "\(stats.limitHits)",
                     info: "Windows\(scope) that reached 95% or more used — you ran out, or nearly ran out, before the window reset.",
                     tint: stats.limitHits > 0 ? DS.C.usageRed : nil)
            statTile("Weekly", value: weekly.map(percent) ?? "–",
                     info: combined
                        ? "The highest weekly quota use among your accounts, from each one's latest reading. Weekly quotas reset once a week."
                        : "How much of your weekly quota is used, from the latest reading. It resets once a week.")
        }
    }

    private func statTile(_ title: String, value: String, info: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .dsSectionLabel()
                .lineLimit(1)
                .fixedSize()
            HStack(alignment: .center, spacing: 2) {
                Text(value)
                    .font(.system(size: 17, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(tint ?? DS.C.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                InfoButton(title: title, text: info)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .dsCard(radius: DS.R.md)
    }

    // MARK: - Cards

    private var emptyCard: some View {
        let anyMonitored = series.contains(where: \.isMonitored)
        return card(title: "Quota usage", info: Self.usageInfo(combined: combined)) {
            VStack(alignment: .leading, spacing: 4) {
                Text("No readings in this range yet.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.C.text)
                Text(anyMonitored
                     ? "QuotaWarmer saves a reading on every quota check; charts fill in over the next few hours."
                     : "Monitoring is Off. Switch an account to Monitor to start recording quota history.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DS.C.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
    }

    private var usageCard: some View {
        let end = Date()
        let start = end.addingTimeInterval(-range.interval)
        return card(title: "Quota used", info: Self.usageInfo(combined: combined), trailing: legend) {
            Chart {
                ForEach(series) { entry in
                    let color = lineColor(entry)
                    let session = UsageHistory.chartPoints(entry.samples) { $0.s.map { $0 * 100 } }
                    // A lone reading (first poll, or one between gaps) draws no line.
                    let segmentSizes = Dictionary(grouping: session, by: \.segment).mapValues(\.count)
                    let lonePoints = session.filter { segmentSizes[$0.segment] == 1 }
                    let weekly = UsageHistory.chartPoints(entry.samples) { $0.w.map { $0 * 100 } }
                    ForEach(session) { point in
                        if !combined {
                            AreaMark(
                                x: .value("Time", point.t),
                                y: .value("Session", point.value),
                                series: .value("Segment", "\(entry.id)-s\(point.segment)")
                            )
                            .foregroundStyle(color.opacity(0.14))
                            .interpolationMethod(.stepEnd)
                        }
                        LineMark(
                            x: .value("Time", point.t),
                            y: .value("Session", point.value),
                            series: .value("Segment", "\(entry.id)-s\(point.segment)")
                        )
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.stepEnd)
                    }
                    ForEach(lonePoints) { point in
                        PointMark(x: .value("Time", point.t), y: .value("Session", point.value))
                            .foregroundStyle(color)
                            .symbolSize(18)
                    }
                    ForEach(weekly) { point in
                        LineMark(
                            x: .value("Time", point.t),
                            y: .value("Weekly", point.value),
                            series: .value("Segment", "\(entry.id)-w\(point.segment)")
                        )
                        .foregroundStyle(combined ? color.opacity(0.75) : DS.C.textSub)
                        .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                    }
                }
            }
            .chartXScale(domain: start...end)
            .chartYScale(domain: 0...100)
            .chartPlotStyle { $0.clipped() }
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                    AxisGridLine().foregroundStyle(DS.C.borderSoft)
                    AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%").font(.system(size: 8.5)) }
                }
            }
            .chartXAxis { timeAxis }
            .frame(height: 120)
        }
    }

    @ViewBuilder
    private var legend: some View {
        if combined {
            HStack(spacing: 8) {
                ForEach(series) { entry in
                    legendItem(entry.tool.shortName, color: lineColor(entry), dashed: false)
                }
                legendItem("Weekly", color: DS.C.textSub, dashed: true)
            }
        } else {
            HStack(spacing: 8) {
                legendItem("5h", color: series.first.map(lineColor) ?? DS.C.usageBlue, dashed: false)
                legendItem("Weekly", color: DS.C.textSub, dashed: true)
            }
        }
    }

    private func legendItem(_ label: String, color: Color, dashed: Bool) -> some View {
        HStack(spacing: 4) {
            Capsule()
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [2, 2] : []))
                .frame(width: 12, height: 1.5)
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(DS.C.textMuted).lineLimit(1)
        }
    }

    private func windowCard(_ windowsByAccount: [(HistorySeries, [QuotaWindowSummary])]) -> some View {
        let end = Date()
        let start = end.addingTimeInterval(-range.interval)
        var visible: [WindowBar] = []
        for (entry, windows) in windowsByAccount {
            for window in windows where window.resetAt >= start {
                let barStart = max(window.startAt, start)
                let barEnd = min(window.resetAt, end)
                guard barEnd > barStart else { continue }
                // Accounts overlap in time, so combined bars are see-through.
                let color: Color = combined ? lineColor(entry).opacity(0.6) : barColor(window.peakUsed)
                visible.append(WindowBar(
                    id: "\(entry.id)-\(window.resetAt.timeIntervalSince1970)",
                    window: window,
                    start: barStart,
                    end: barEnd,
                    color: color
                ))
            }
        }
        var info = "One bar per 5-hour window, spanning the hours it was open; its height is the most of the window that was used before it reset."
        info += combined
            ? " Each account is drawn in its own color, see-through where windows overlap."
            : " Blue under 50%, orange from 50%, red from 80% used."
        return card(title: "Peak per 5h window", info: info) {
            if visible.isEmpty {
                Text("No opened windows in this range.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DS.C.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Chart(visible) { bar in
                    // Spans the window's real 5 hours, so bars read as time on
                    // the same axis as the usage chart above.
                    RectangleMark(
                        xStart: .value("Start", bar.start),
                        xEnd: .value("Reset", bar.end),
                        yStart: .value("Base", 0.0),
                        yEnd: .value("Peak", bar.window.peakUsed * 100)
                    )
                    .foregroundStyle(bar.color)
                    .cornerRadius(2)
                }
                .chartXScale(domain: start...end)
                .chartYScale(domain: 0...100)
                .chartPlotStyle { $0.clipped() }
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                        AxisGridLine().foregroundStyle(DS.C.borderSoft)
                        AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%").font(.system(size: 8.5)) }
                    }
                }
                .chartXAxis { timeAxis }
                .frame(height: 96)
            }
        }
    }

    /// Token bars built from local-time hours, like Busy hours: one bar per
    /// hour for 24h, per local day for 7d / 30d. Accounts stack.
    private var dailyTokensCard: some View {
        let now = Date()
        let calendar = Calendar.current
        let hourlyView = range == .day
        let bars: [(HistorySeries, [TokenUsageHour])] = series.map { entry in
            let hours = entry.tokens?.hourly ?? []
            let buckets = hourlyView
                ? UsageHistory.recentHours(hours, count: 24, now: now, calendar: calendar)
                : UsageHistory.dayTotals(hours, days: range.dayCount, now: now, calendar: calendar)
            return (entry, buckets)
        }
        let overall = UsageHistory.total(bars.flatMap(\.1), at: now)
        let subtitle = "\(TokenFormat.compact(overall.tokens)) tokens" + (overall.costUSD.map { " · $\(String(format: "%.2f", $0))" } ?? "")
        let reading = series.contains(where: \.isFetchingTokens)
        let unit: Calendar.Component = hourlyView ? .hour : .day
        var info = hourlyView
            ? "Tokens in each of the last 24 hours (your local time)"
            : "Tokens per day (your local time) over the \(range.longLabel)"
        info += ", from the CLI's local logs on this Mac (input, output and cache), with the estimated API-equivalent cost. Usage on other machines or the web isn't included."
        if combined { info += " Each account is a segment of the bar." }
        return card(title: hourlyView ? "Hourly tokens" : "Daily tokens", info: info, trailing: Text(subtitle)
            .font(.system(size: 9.5, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(DS.C.textMuted)) {
            if overall.tokens == 0 {
                Text(reading ? "Reading local logs…" : "No local CLI usage in this range.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DS.C.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                // Bars in the same hour/day stack, one segment per account.
                Chart {
                    ForEach(bars, id: \.0.id) { entry, buckets in
                        ForEach(buckets, id: \.hour) { bucket in
                            BarMark(
                                x: .value("Time", bucket.hour, unit: unit),
                                y: .value("Tokens", bucket.tokens)
                            )
                            .foregroundStyle(tokenColor(entry))
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(DS.C.borderSoft)
                        AxisValueLabel { Text(TokenFormat.compact(value.as(Int.self) ?? 0)).font(.system(size: 8.5)) }
                    }
                }
                .chartXAxis { tokenAxis }
                .frame(height: 96)
            }
        }
    }

    @AxisContentBuilder
    private var tokenAxis: some AxisContent {
        switch range {
        case .day:
            AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                AxisValueLabel(format: .dateTime.hour()).font(.system(size: 8.5))
            }
        case .week:
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.narrow)).font(.system(size: 8.5))
            }
        case .month:
            AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.system(size: 8.5))
            }
        }
    }

    private var heatmapCard: some View {
        // By tool, not account: two Claude accounts are both "Claude" here.
        var byKind: [ToolID: [[TokenUsageHour]]] = [:]
        for entry in series { byKind[entry.tool.kind, default: []].append(entry.tokens?.hourly ?? []) }
        let hourlyByKind = byKind.mapValues { UsageHistory.mergeHourly($0) }
        let grid = BusyHoursGrid.make(range: range, hourlyByKind: hourlyByKind, now: Date(), calendar: .current)
        let kinds = ToolID.allCases.filter { kind in grid.rows.contains { $0.cells.contains { ($0?.parts[kind] ?? 0) > 0 } } }
        let showsBoth = grid.rows.contains { $0.cells.contains { $0.map { BusyHoursGrid.tint(of: $0) == nil } ?? false } }
        let scope = combined
            ? " Orange is Claude and purple is Codex; a square used by both (neither above 80% of its tokens) is pink."
            : ""
        let info: String
        switch range {
        case .day:
            info = "Tokens in each of the last 24 hours (your local time), the newest on the right. Darker squares mean more tokens; hover a square for its total." + scope
        case .week:
            info = "Each row is one of the last 7 days, today at the bottom; each column is an hour of the day, 00 to 23 (your local time). Darker squares mean more tokens; hover a square for its total." + scope
        case .month:
            info = "Your usual week: rows are weekdays, columns the hours 00 to 23 (your local time), and each square adds up that weekday and hour over the last 30 days — so it shows when you tend to use the CLI. Darker squares mean more tokens; hover a square for its total." + scope
        }
        return card(title: "Busy hours · \(range.label)", info: info, trailing: busyLegend(kinds: combined ? kinds : [], both: combined && showsBoth)) {
            if grid.peak == 0 {
                Text("No local CLI usage in this range.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DS.C.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else {
                HourHeatmap(grid: grid)
            }
        }
    }

    @ViewBuilder
    private func busyLegend(kinds: [ToolID], both: Bool) -> some View {
        if !kinds.isEmpty {
            HStack(spacing: 7) {
                ForEach(kinds) { kind in swatch(kind.shortName, DS.C.accent(kind)) }
                if both { swatch("Both", DS.C.bothAccent) }
            }
        }
    }

    private func swatch(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: 8, height: 8)
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(DS.C.textMuted).lineLimit(1)
        }
    }

    // MARK: - Helpers

    /// Session-line color: usage blue for a single account, the account's
    /// brand color when several share a chart (added accounts a shade lighter).
    private func lineColor(_ entry: HistorySeries) -> Color {
        guard combined else { return colorfulBars ? DS.C.usageBlue : DS.C.barPlain }
        return DS.C.accent(entry.tool).opacity(entry.tool.isDefault ? 1 : 0.55)
    }

    private func tokenColor(_ entry: HistorySeries) -> Color {
        DS.C.accent(entry.tool).opacity(entry.tool.isDefault ? 0.85 : 0.5)
    }

    private func barColor(_ used: Double) -> Color {
        guard colorfulBars else { return DS.C.barPlain }
        return DS.C.usage(QuotaUsageLevel(remainingFraction: 1 - used))
    }

    @AxisContentBuilder
    private var timeAxis: some AxisContent {
        switch range {
        case .day:
            AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                AxisGridLine().foregroundStyle(DS.C.borderSoft)
                AxisValueLabel(format: .dateTime.hour()).font(.system(size: 8.5))
            }
        case .week:
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisGridLine().foregroundStyle(DS.C.borderSoft)
                AxisValueLabel(format: .dateTime.weekday(.narrow)).font(.system(size: 8.5))
            }
        case .month:
            AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                AxisGridLine().foregroundStyle(DS.C.borderSoft)
                AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.system(size: 8.5))
            }
        }
    }

    static func usageInfo(combined: Bool) -> String {
        "How much of the quota was used over time. The solid line is the 5-hour window — it drops back to 0 when the window resets; the dashed line is the weekly quota. Gaps are times QuotaWarmer wasn't checking (Mac asleep or app closed)."
            + (combined ? " Each account has its own color." : "")
    }

    private func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    private func card<Content: View>(title: String, info: String, @ViewBuilder content: () -> Content) -> some View {
        card(title: title, info: info, trailing: EmptyView(), content: content)
    }

    private func card<Trailing: View, Content: View>(
        title: String,
        info: String,
        trailing: Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).dsSectionLabel().lineLimit(1).fixedSize()
                Spacer(minLength: 6)
                trailing
                InfoButton(title: title.capitalized, text: info)
            }
            content()
        }
        .padding(DS.Page.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }
}

/// Rows of hour cells for the busy-hours card, shaped by the range:
/// 24h → one row of the last 24 hours; 7d → one row per real day; 30d → the
/// average week (weekday × hour totals).
struct BusyHoursGrid {
    struct Cell {
        let value: Int
        let tooltip: String
        /// Tokens per tool within `value`.
        var parts: [ToolID: Int] = [:]
    }

    /// Share at or above which a cell takes one tool's color.
    static let dominantShare = 0.8

    /// The tool a cell belongs to, or nil when no tool reaches
    /// `dominantShare` (used together) — or it has no tokens at all.
    static func tint(of cell: Cell) -> ToolID? {
        guard cell.value > 0 else { return nil }
        return cell.parts.first { Double($0.value) / Double(cell.value) >= dominantShare }?.key
    }

    /// Builds the grid from the per-tool totals and records each cell's
    /// per-tool split, with a breakdown in the tooltip when tools mix.
    static func make(range: HistoryRange, hourlyByKind: [ToolID: [TokenUsageHour]], now: Date, calendar: Calendar) -> BusyHoursGrid {
        let total = make(range: range, hourly: UsageHistory.mergeHourly(Array(hourlyByKind.values)), now: now, calendar: calendar)
        let perKind = hourlyByKind.mapValues { make(range: range, hourly: $0, now: now, calendar: calendar) }
        let rows = total.rows.enumerated().map { r, row in
            Row(label: row.label, cells: row.cells.enumerated().map { c, cell -> Cell? in
                guard var cell else { return nil }
                for (kind, grid) in perKind {
                    if let value = grid.rows[r].cells[c]?.value, value > 0 { cell.parts[kind] = value }
                }
                if cell.parts.count > 1 {
                    let split = ToolID.allCases.compactMap { kind in
                        cell.parts[kind].map { "\(kind.shortName) \(TokenFormat.compact($0))" }
                    }
                    cell = Cell(value: cell.value, tooltip: cell.tooltip + " (" + split.joined(separator: ", ") + ")", parts: cell.parts)
                }
                return cell
            })
        }
        return BusyHoursGrid(rows: rows, axis: total.axis, cellHeight: total.cellHeight, labelWidth: total.labelWidth)
    }

    struct Row {
        let label: String
        /// nil = an hour that hasn't happened yet.
        let cells: [Cell?]
    }

    let rows: [Row]
    /// Column index → hour label under the grid.
    let axis: [(column: Int, label: String)]
    let cellHeight: CGFloat
    let labelWidth: CGFloat

    var peak: Int { rows.flatMap(\.cells).compactMap { $0?.value }.max() ?? 0 }

    static func make(range: HistoryRange, hourly: [TokenUsageHour], now: Date, calendar: Calendar) -> BusyHoursGrid {
        // Columns are the 24 hours of the day; label every third one.
        let hourAxis = stride(from: 0, to: 24, by: 3).map { (column: $0, label: String(format: "%02d", $0)) }
        switch range {
        case .day:
            let hours = UsageHistory.recentHours(hourly, count: 24, now: now, calendar: calendar)
            let cells: [Cell?] = hours.map {
                Cell(value: $0.tokens, tooltip: "\(hourText($0.hour, calendar)) · \(TokenFormat.compact($0.tokens)) tokens")
            }
            // Label every column whose clock hour is a multiple of 6.
            let axis = hours.enumerated().compactMap { index, entry -> (column: Int, label: String)? in
                let hour = calendar.component(.hour, from: entry.hour)
                return hour % 3 == 0 ? (column: index, label: String(format: "%02d", hour)) : nil
            }
            return BusyHoursGrid(rows: [Row(label: "", cells: cells)], axis: axis, cellHeight: 22, labelWidth: 0)

        case .week:
            // A date on every row, so it reads as the last 7 days, not a
            // weekday pattern (that's the 30d view).
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("EEE d")
            let full = DateFormatter()
            full.setLocalizedDateFormatFromTemplate("EEE d MMM")
            let rows = UsageHistory.dayRows(hourly, days: 7, now: now, calendar: calendar).map { row in
                let isToday = calendar.isDate(row.day, inSameDayAs: now)
                let cells: [Cell?] = row.cells.enumerated().map { hour, value in
                    value.map { Cell(value: $0, tooltip: "\(full.string(from: row.day)) \(hour):00 · \(TokenFormat.compact($0)) tokens") }
                }
                return Row(label: isToday ? "Today" : formatter.string(from: row.day), cells: cells)
            }
            return BusyHoursGrid(rows: rows, axis: hourAxis, cellHeight: 9, labelWidth: 38)

        case .month:
            let since = calendar.date(byAdding: .day, value: -30, to: now) ?? now
            let totals = UsageHistory.hourOfWeek(hourly, since: since, calendar: calendar)
            let symbols = calendar.shortWeekdaySymbols
            // Calendar weekday numbers (Sunday = 1), Monday first.
            let rows = [2, 3, 4, 5, 6, 7, 1].map { weekday in
                let name = symbols[weekday - 1]
                let cells: [Cell?] = (0..<24).map { hour in
                    let value = totals[(weekday - 1) * 24 + hour]
                    return Cell(value: value, tooltip: "\(name) \(hour):00 · \(TokenFormat.compact(value)) tokens over 30 days")
                }
                return Row(label: name, cells: cells)
            }
            return BusyHoursGrid(rows: rows, axis: hourAxis, cellHeight: 9, labelWidth: 28)
        }
    }

    private static func hourText(_ date: Date, _ calendar: Calendar) -> String {
        "\(calendar.component(.hour, from: date)):00"
    }
}

private struct HourHeatmap: View {
    let grid: BusyHoursGrid

    private func color(for cell: BusyHoursGrid.Cell) -> Color {
        BusyHoursGrid.tint(of: cell).map { DS.C.accent($0) } ?? DS.C.bothAccent
    }

    var body: some View {
        let peak = grid.peak
        VStack(alignment: .leading, spacing: 2) {
            // Hours above the grid, like column headers.
            axis
            ForEach(Array(grid.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 2) {
                    if grid.labelWidth > 0 {
                        Text(row.label)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(DS.C.textMuted)
                            .lineLimit(1)
                            .frame(width: grid.labelWidth, alignment: .leading)
                    }
                    ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                        if let cell {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(cell.value == 0 ? DS.C.track : color(for: cell).opacity(0.18 + 0.82 * intensity(cell.value, peak: peak)))
                                .frame(height: grid.cellHeight)
                                .help(cell.tooltip)
                        } else {
                            // Not yet: an outline keeps the row's 24-hour shape.
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .stroke(DS.C.borderSoft, lineWidth: 1)
                                .frame(height: grid.cellHeight)
                        }
                    }
                }
            }
        }
    }

    /// Hour labels centred over their columns (24 equal columns, 2pt gaps).
    private var axis: some View {
        HStack(spacing: 2) {
            if grid.labelWidth > 0 { Spacer().frame(width: grid.labelWidth) }
            GeometryReader { geo in
                let pitch = (geo.size.width + 2) / 24
                ForEach(grid.axis, id: \.column) { mark in
                    Text(mark.label)
                        .font(.system(size: 8))
                        .monospacedDigit()
                        .foregroundStyle(DS.C.textMuted)
                        .fixedSize()
                        .frame(width: pitch - 2)
                        .offset(x: CGFloat(mark.column) * pitch)
                }
            }
            .frame(height: 10)
        }
    }

    /// Square-root scale so a few very heavy hours don't wash out the rest.
    private func intensity(_ value: Int, peak: Int) -> Double {
        guard peak > 0 else { return 0 }
        return (Double(value) / Double(peak)).squareRoot()
    }
}

enum TokenFormat {
    static func compact(_ tokens: Int) -> String {
        let value = Double(tokens)
        switch value {
        case 1_000_000_000...: return String(format: "%.1fB", value / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", value / 1_000_000)
        case 1_000...: return String(format: "%.0fK", value / 1_000)
        default: return "\(tokens)"
        }
    }
}

/// ⓘ that explains a stat: opens on hover, and a click pins it open (click
/// again or move away to close). A popover rather than `.help`, whose tooltip
/// is slow and unreliable in this non-activating panel.
struct InfoButton: View {
    let title: String
    let text: String

    @State private var hovering = false
    @State private var pinned = false

    var body: some View {
        Button(action: { pinned.toggle() }) {
            Image(systemName: "info.circle")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(hovering || pinned ? DS.C.textSub : DS.C.textMuted)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: Binding(
            get: { hovering || pinned },
            set: { if !$0 { hovering = false; pinned = false } }
        ), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(DS.C.text)
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.C.textSub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(width: 220, alignment: .leading)
        }
        .accessibilityLabel(Text("About \(title)"))
        .accessibilityHint(Text(text))
    }
}
