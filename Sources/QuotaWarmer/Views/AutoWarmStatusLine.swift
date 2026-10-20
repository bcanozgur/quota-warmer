import SwiftUI

/// One compact "why didn't it warm?" line for a provider card, with an info
/// popover carrying the full explanation. Off shows nothing; Monitor shows a
/// single muted line.
struct AutoWarmStatusLine: View {
    @ObservedObject var toolState: ToolState
    var now: Date = Date()
    @State private var showDetail = false

    private var explanation: AutoWarmExplanation? {
        let e = AutoWarmExplanation.make(
            AutoWarmExplanation.Input(
                mode: toolState.mode,
                skip: toolState.lastAutoWarmSkip,
                decidedAt: toolState.lastAutoWarmDecisionAt,
                nextCheckAt: toolState.nextRefreshAt,
                windowResetAt: toolState.resetAt,
                snapshotFetchedAt: toolState.quotaSnapshot?.fetchedAt
            ),
            now: now
        )
        return toolState.mode == .off ? nil : e
    }

    var body: some View {
        if let e = explanation {
            Button { showDetail.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: e.tone == .attention ? "exclamationmark.circle" : "info.circle")
                        .font(.system(size: 10, weight: .medium))
                    Text(e.status)
                        .font(.system(size: e.isSubtle ? 10.5 : 11, weight: .medium))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(color(e.tone, subtle: e.isSubtle))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(e.popoverLines(now: now).joined(separator: "\n"))
            .popover(isPresented: $showDetail, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(e.status)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.C.text)
                    ForEach(Array(e.popoverLines(now: now).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11))
                            .foregroundStyle(DS.C.textSub)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 260, alignment: .leading)
                .padding(DS.Page.cardPadding)
            }
        }
    }

    private func color(_ tone: AutoWarmExplanation.Tone, subtle: Bool) -> Color {
        switch tone {
        case .attention: return DS.C.yellow
        case .good: return DS.C.green
        case .neutral: return subtle ? DS.C.textMuted : DS.C.textSub
        }
    }
}
