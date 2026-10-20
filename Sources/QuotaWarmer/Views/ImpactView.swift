import Charts
import SwiftUI

/// Switch between the History charts and the Impact panel.
struct HistoryModeToggle: View {
    @Binding var showImpact: Bool

    var body: some View {
        HStack(spacing: 2) {
            segment("History", selected: !showImpact) { showImpact = false }
            segment("Impact", selected: showImpact) { showImpact = true }
        }
        .padding(2)
        .background(DS.C.surfaceHigh, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(selected ? DS.C.surface : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(selected ? DS.C.border : .clear, lineWidth: 1))
                .foregroundStyle(selected ? DS.C.text : DS.C.textMuted)
        }
        .buttonStyle(PressableButtonStyle())
    }
}

/// What QuotaWarmer has earned you: windows claimed, head start gained, what
/// the warm-ups cost, and how well the windows were used. Computed from the
/// stored event log, quota samples and local usage (`ImpactReport`).
struct ImpactView: View {
    let providers: [ProviderID]

    @EnvironmentObject var appState: AppState
    @AppStorage("impactRange") private var rangeRaw = ImpactRange.month.rawValue
    @State private var events: [HistoryEvent] = []
    @State private var samplesByKey: [String: [QuotaSample]] = [:]
    @State private var loaded = false

    private var range: ImpactRange { ImpactRange(rawValue: rangeRaw) ?? .month }

    private var loadKey: String {
        let fetches = providers
            .map { String(Int(appState.state(for: $0).lastSuccessfulFetch?.timeIntervalSince1970 ?? 0)) }
            .joined(separator: ",")
        return "\(providers.map(\.storageKey).joined(separator: ","))|\(appState.history.count)|\(fetches)"
    }

    private var report: ImpactReport {
        let inputs = providers.map { tool in
            ImpactInput(
                provider: tool,
                events: events,
                samples: samplesByKey[tool.storageKey] ?? [],
                hourly: appState.state(for: tool).tokenUsageSummary?.hourly ?? [],
                windowDuration: tool.windowDuration
            )
        }
        return ImpactReport.make(inputs: inputs, range: range, now: Date()) { kind, model in
            ModelCatalogStore.shared(for: kind).catalog?.model(for: model)
        }
    }

    var body: some View {
        let report = report
        VStack(alignment: .leading, spacing: DS.Page.spacing) {
            HStack {
                Spacer(minLength: 0)
                rangePicker
            }
            if !loaded {
                Text("Loading…").font(.system(size: 10.5)).foregroundStyle(DS.C.textMuted)
            } else if report.isEmpty {
                emptyCard
            } else {
                tiles(report)
                if report.buckets.contains(where: { $0.total > 0 }) { claimsCard(report) }
                detailCard(report)
            }
        }
        .task(id: loadKey) {
            events = await EventLogStore.shared.recent(limit: EventLogStore.maxLines)
            var loadedSamples: [String: [QuotaSample]] = [:]
            for tool in providers {
                loadedSamples[tool.storageKey] = await UsageHistoryStore.shared.samples(for: tool, since: .distantPast)
            }
            samplesByKey = loadedSamples
            loaded = true
        }
    }

    // MARK: - Pieces

    private var rangePicker: some View {
        HStack(spacing: 2) {
            ForEach(ImpactRange.allCases) { option in
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
            }
        }
        .padding(2)
        .background(DS.C.surfaceHigh, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var emptyCard: some View {
        card(title: "Impact", info: Self.overviewInfo) {
            Text("Not enough data yet — impact appears after the first claimed window.")
                .font(.system(size: 11))
                .foregroundStyle(DS.C.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tiles(_ report: ImpactReport) -> some View {
        let claims = report.claims
        return HStack(spacing: 8) {
            tile("Claimed", value: "\(claims.claimed)",
                 info: "5-hour windows QuotaWarmer opened for you and the live quota confirmed. Missed or failed warm-ups are not counted.")
            tile("Success", value: claims.successRate.map(Self.percent) ?? "–",
                 info: "Confirmed windows out of every warm-up that finished (confirmed, missed or failed).")
            tile("Head start", value: report.headStart.total > 0 ? Self.duration(report.headStart.total) : "–",
                 info: Self.headStartInfo)
        }
    }

    private func claimsCard(_ report: ImpactReport) -> some View {
        let claims = report.claims
        var parts: [String] = []
        if claims.auto > 0 { parts.append("\(claims.auto) auto") }
        if claims.morning > 0 { parts.append("\(claims.morning) morning") }
        if claims.manual > 0 { parts.append("\(claims.manual) manual") }
        if claims.intent > 0 { parts.append("\(claims.intent) shortcut") }
        if claims.unattributed > 0 { parts.append("\(claims.unattributed) earlier") }
        return card(
            title: "Windows claimed",
            info: "How many windows were opened by a warm-up each \(range == .all ? "week" : "day"). Auto = fresh window detected; morning = the daily pre-warm; manual = you pressed Warm up.",
            trailing: Text(parts.joined(separator: " · "))
                .font(.system(size: 9, weight: .medium)).foregroundStyle(DS.C.textMuted).lineLimit(1)
        ) {
            Chart {
                ForEach(report.buckets) { bucket in
                    BarMark(x: .value("Day", bucket.start, unit: range == .all ? .weekOfYear : .day),
                            y: .value("Claimed", bucket.total))
                        .foregroundStyle(DS.C.usageBlue)
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(DS.C.borderSoft)
                    AxisValueLabel().font(.system(size: 8.5))
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.system(size: 8.5))
                }
            }
            .frame(height: 70)
        }
    }

    private func detailCard(_ report: ImpactReport) -> some View {
        let head = report.headStart
        let util = report.utilization
        let claims = report.claims
        return card(title: "Details", info: Self.overviewInfo) {
            VStack(alignment: .leading, spacing: 6) {
                row("Missed / failed", "\(claims.missed) / \(claims.failed)",
                    help: "Warm-ups whose window never showed in live quota, or whose command failed.")
                row("Avg head start", head.average.map(Self.duration) ?? "–",
                    help: Self.headStartInfo)
                if head.unusedWindows > 0 {
                    row("Claimed, unused", "\(head.unusedWindows)",
                        help: "Claimed windows that ended with no local CLI usage, so no head start was measured.")
                }
                row("Warm-up cost", report.cost.displayText + (report.cost.warmups > 0 ? " · est." : ""),
                    help: "\(report.cost.warmups) warm-ups × about 15K input and 100 output tokens at the catalog price of the model used. An estimate, not billing data; \"unpriced\" means the model is not in the price catalog yet.")
                row("Windows ≥ 80% used", util.highUseShare.map { "\(Self.percent($0)) of \(util.windows)" } ?? "–",
                    help: "Share of observed 5-hour windows whose peak use reached 80%. Low means quota went unused.")
                row("Weeks at weekly limit", util.weeks == 0 ? "–" : "\(util.weeksAtLimit) of \(util.weeks)",
                    help: "Calendar weeks where the weekly quota reached 95%.")
            }
        }
    }

    private func row(_ title: String, _ value: String, help: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(DS.C.textSub)
            Spacer(minLength: 6)
            Text(value).font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(DS.C.text)
            InfoButton(title: title, text: help)
        }
    }

    private func tile(_ title: String, value: String, info: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).dsSectionLabel().lineLimit(1).fixedSize()
            HStack(spacing: 2) {
                Text(value)
                    .font(.system(size: 17, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(DS.C.text)
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

    private func card<Content: View>(title: String, info: String, @ViewBuilder content: () -> Content) -> some View {
        card(title: title, info: info, trailing: EmptyView(), content: content)
    }

    private func card<Trailing: View, Content: View>(
        title: String, info: String, trailing: Trailing, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).dsSectionLabel().lineLimit(1).fixedSize()
                Spacer(minLength: 6)
                trailing
                InfoButton(title: title, text: info)
            }
            content()
        }
        .padding(DS.Page.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    // MARK: - Text

    static let overviewInfo = "What QuotaWarmer has done for you, from its own event log, your quota history and the CLI's local logs on this Mac."
    static let headStartInfo = "How much earlier your windows reset than if each had started at your first real use. A warm-up opens the window before you work, so the quota refreshes sooner. Measured from the window's start to your first local CLI activity, at most one full window per claim."

    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 48 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }
}
