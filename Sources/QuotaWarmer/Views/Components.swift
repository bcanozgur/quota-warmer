import SwiftUI

// Reusable UI primitives shared across the in-app screens. Tuned to the
// OpenUsage visual language: slim usage bars, muted status dots/badges, and
// quiet native-feeling controls with very subtle hover/press states.

/// Slim, gradient-free usage bar: a track tinted with the fill color (like
/// claude.ai's usage page) + a solid fill. The fill shows quota left or used,
/// depending on the tool's display mode. An optional `thumbFraction` draws a
/// slider-style knob marking the window's time (see `QuotaDisplay.thumbFraction`)
/// — when fill and knob disagree, quota is being spent faster than time.
struct UsageBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var fraction: Double
    var refreshing: Bool = false
    var height: CGFloat = 8
    var fill: Color = DS.C.ink
    var track: Color = DS.C.track
    var thumbFraction: Double? = nil

    private func clamp(_ value: Double) -> CGFloat { CGFloat(min(max(value, 0), 1)) }

    var body: some View {
        // The refresh pulse is computed from the clock, not an implicit
        // repeatForever animation: that animation also caught every layout change
        // made while it ran (countdown ticks, panel resizes) and replayed it forever,
        // so the fill bobbed up and down away from the knob and the row titles.
        // Reduce Motion: no pulse; the fill stays solid while a refresh runs.
        TimelineView(.animation(paused: !refreshing || reduceMotion)) { context in
            bar(fillOpacity: refreshing && !reduceMotion ? pulseOpacity(at: context.date) : 1)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    /// 1 → 0.7 → 1 every 1.6 s.
    private func pulseOpacity(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate * .pi / 0.8
        return 0.85 + 0.15 * cos(phase)
    }

    private func bar(fillOpacity: Double) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fillW = max(0, w * clamp(fraction))
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(fill)
                    .frame(width: fillW)
                    .opacity(fillOpacity)
                if let thumbFraction {
                    let thumbW: CGFloat = 5
                    Capsule()
                        .fill(DS.C.knob)
                        .overlay(Capsule().stroke(DS.C.textMuted, lineWidth: 1))
                        .frame(width: thumbW, height: height + 5)
                        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                        .offset(x: min(max(w * clamp(thumbFraction) - thumbW / 2, 0), w - thumbW))
                }
            }
        }
    }
}

/// Banked, expiring rate-limit resets (Codex). Count on the header line, then one
/// line per grant with its expiry, soonest first. Each line has a two-step button:
/// "Use" arms it ("Sure?", auto-disarms after a few seconds), a second tap redeems.
struct ResetCreditsRow: View {
    var credits: [ResetCredit]
    var now: Date
    var onUse: (ResetCredit) async -> String?

    @State private var armedID: String?
    @State private var busyID: String?
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Banked resets")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.C.text)
                Spacer(minLength: 8)
                Text("\(credits.count) available")
                    .font(DS.mono(11, weight: .semibold))
                    .foregroundStyle(DS.C.textSub)
            }
            ForEach(credits, id: \.id) { credit in
                HStack(spacing: 8) {
                    Text(credit.expiresAt.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.C.textSub)
                    Text("expires in \(quotaDurationText(max(0, Int(credit.expiresAt.timeIntervalSince(now)))))")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.C.textMuted)
                    Spacer(minLength: 8)
                    useButton(credit)
                }
            }
            if let errorText {
                Text(errorText)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(DS.C.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func useButton(_ credit: ResetCredit) -> some View {
        let busy = busyID == credit.id
        let armed = armedID == credit.id
        return Button {
            errorText = nil
            if armed {
                armedID = nil
                busyID = credit.id
                Task {
                    errorText = await onUse(credit)
                    busyID = nil
                }
            } else {
                armedID = credit.id
                // Disarm if the second tap never comes.
                Task {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if armedID == credit.id { armedID = nil }
                }
            }
        } label: {
            Text(busy ? String(localized: "Using…") : armed ? String(localized: "Sure?") : String(localized: "Use"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(armed ? DS.C.red : DS.C.text)
                .frame(minWidth: 52)
                .padding(.vertical, 3)
                .background(Capsule().fill((armed ? DS.C.red : DS.C.textMuted).opacity(0.14)))
                .overlay(Capsule().stroke((armed ? DS.C.red : DS.C.border).opacity(armed ? 0.5 : 1), lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(busyID != nil)
        .help(armed ? String(localized: "Click again to use this reset now") : String(localized: "Use this banked reset (asks to confirm)"))
    }
}

@MainActor
enum ToolStatusCopy {
    static func quotaLeftText(for state: ToolState, metric: QuotaMetric?, settling: Bool = false) -> String {
        if settling { return String(localized: "Updating...") }
        return QuotaDisplay.quotaText(
            remainingFraction: metric?.remainingFraction,
            isLive: isLive(state),
            mode: state.displayMode
        )
    }

    static func resetFallback(for state: ToolState, metric: QuotaMetric?) -> String {
        guard let metric else {
            if state.isFetchingQuota { return String(localized: "Updating...") }
            return authBlocked(state) ? String(localized: "Connect to update") : String(localized: "No live quota")
        }
        if metric.isIdleFiveHourWindow {
            // The window hasn't opened yet — its quota is full and the only reset
            // is a sliding projection. Say so plainly instead of faking a countdown.
            return String(localized: "Not started yet")
        }
        if authBlocked(state) {
            return state.lastSuccessfulFetch == nil
                ? String(localized: "Connect to update") : String(localized: "Reconnect to update")
        }
        switch state.freshness {
        case .fresh:
            return String(localized: "Fresh")
        case .stale, .expired:
            if let fetched = state.lastSuccessfulFetch {
                return String(localized: "Last checked \(shortClock(fetched))")
            }
            return String(localized: "Last known")
        case .unknown:
            return String(localized: "No live quota")
        }
    }

    static func providerIssue(for state: ToolState) -> String? {
        if authBlocked(state) {
            var message = authActionText(for: state)
            if let retryAt = state.authRetryScheduledAt, retryAt > Date() {
                message += " " + String(localized: "Auto-check at \(shortClock(retryAt)).")
            }
            if state.lastSuccessfulFetch != nil {
                message += " " + String(localized: "Last quota is shown for context.")
            }
            return message
        }
        if state.quotaBackoffActive, let until = state.quotaBackoffUntil {
            return String(localized: "Quota source is rate-limited. Retrying at \(shortClock(until)).")
        }
        if state.tool.kind == .claude,
           state.healthMessage.contains("quota credential needs a CLI refresh") {
            return String(localized: "Claude is signed in. Its quota will refresh when Claude runs; the last known reading is shown for context.")
        }
        if state.freshness == .expired, let fetched = state.lastSuccessfulFetch {
            return String(localized: "Live quota has not updated since \(shortClock(fetched)). Showing the last known reading.")
        }
        if state.sourceHealth == .unavailable {
            if state.lastSuccessfulFetch != nil {
                return String(localized: "Quota source is temporarily unavailable. Showing the last known reading.")
            }
            return String(localized: "Quota source is temporarily unavailable.")
        }
        return nil
    }

    static func rowStatusColor(for state: ToolState, hasMetric: Bool) -> Color? {
        guard hasMetric else { return nil }
        if isLive(state) { return nil }
        return DS.C.yellow
    }

    private static func isLive(_ state: ToolState) -> Bool {
        state.isMonitored && state.sourceHealth == .healthy && state.freshness == .fresh
    }

    private static func authBlocked(_ state: ToolState) -> Bool {
        state.sourceHealth == .authFailure || state.authStatus == .failed || state.authStatus == .missing
    }

    private static func authActionText(for state: ToolState) -> String {
        if !state.tool.isDefault {
            return String(localized: "\(state.tool.shortName) needs signing in. Use Sign in under Settings › Accounts, then Refresh.")
        }
        switch state.tool.kind {
        case .claude:
            if state.healthMessage.contains("access needs approval") {
                return String(localized: "Claude access is paused. Click Refresh to approve Keychain access.")
            }
            return String(localized: "Claude needs reconnecting. Run claude auth login in Terminal, then Refresh.")
        case .codex:
            return String(localized: "Codex needs reconnecting. Sign in again, then Refresh.")
        }
    }

    private static func shortClock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// One quota window block: a "Session"/"Weekly" title with a pace status dot, a
/// wide usage bar with the time-pace knob, and one or two meta lines
/// (`X% left` / `Resets in …`, plus `N% short` / `Runs out in …` when behind).
struct QuotaWindowRow: View {
    let title: String
    /// Name read by VoiceOver before the numbers, e.g. "Claude 5-hour window". Defaults to `title`.
    var accessibilityName: String? = nil
    let hasMetric: Bool
    let quotaLeft: Double
    let leftText: String
    let pace: QuotaPace.Result
    var refreshing: Bool = false
    var statusColor: Color? = nil
    /// Dense two-line layout for the overview: title + `% left` on one line,
    /// a slim bar, then reset/pace on a single meta line.
    var compact: Bool = false
    /// Remaining (bar drains) or used (bar fills). Pace/level math stays on
    /// `quotaLeft` either way.
    var displayMode: QuotaDisplayMode = .remaining
    /// A just-opened window whose number hasn't settled: keep the neutral blue.
    var settling: Bool = false

    var body: some View {
        Group {
            if compact { compactBody } else { fullBody }
        }
        // Color is never the only signal: the row reads as one element with the
        // status in words, the percent, and the reset/pace line.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityName ?? title))
        .accessibilityValue(Text(accessibilityValue))
    }

    /// Spoken status words mirror `dotColor` / `statusColor` so the dot's meaning is in text.
    private var accessibilityStatus: String {
        guard hasMetric else { return String(localized: "no live quota") }
        if statusColor != nil { return String(localized: "not live") }
        if pace.timeLeftFraction != nil {
            return pace.isBehind ? String(localized: "behind pace") : String(localized: "on pace")
        }
        if quotaLeft >= 0.5 { return String(localized: "healthy") }
        if quotaLeft >= 0.25 { return String(localized: "running low") }
        return String(localized: "very low")
    }

    private var accessibilityValue: String {
        var parts = [accessibilityStatus, leftText, pace.resetText]
        if let shortPercent = pace.shortPercent {
            parts.append(String(localized: "\(shortPercent)% short"))
            if let runsOut = pace.runsOutText { parts.append(runsOut) }
        }
        return parts.joined(separator: ", ")
    }

    @AppStorage(QuotaDisplay.colorfulBarsKey) private var colorfulBars = true

    /// nil = plain single-color bars (Settings → Colorful Quota Bars off).
    private var level: QuotaUsageLevel? {
        QuotaDisplay.colorLevel(remainingFraction: quotaLeft, hasMetric: hasMetric,
                                settling: settling, colorful: colorfulBars)
    }

    private var barColor: Color { level.map(DS.C.usage) ?? DS.C.barPlain }

    private var trackColor: Color {
        guard hasMetric, level != nil else { return DS.C.track }
        return barColor.opacity(DS.C.usageTrackOpacity)
    }

    private var percentTextColor: Color {
        guard let level, level != .normal else { return DS.C.textSub }
        return barColor
    }

    private func bar(height: CGFloat) -> some View {
        UsageBar(
            fraction: QuotaDisplay.barFraction(remainingFraction: quotaLeft, hasMetric: hasMetric, mode: displayMode),
            refreshing: refreshing,
            height: height,
            fill: barColor,
            track: trackColor,
            thumbFraction: QuotaDisplay.thumbFraction(timeLeftFraction: pace.timeLeftFraction, mode: displayMode)
        )
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.C.text)
                StatusDot(color: statusColor ?? dotColor, size: 7)
                Spacer(minLength: 6)
                Text(leftText)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(percentTextColor)
                    .monospacedDigit()
            }

            bar(height: 8)

            HStack(spacing: 6) {
                Text(pace.resetText)
                    .foregroundStyle(DS.C.textMuted)
                Spacer(minLength: 6)
                if let shortPercent = pace.shortPercent {
                    Text([ String(localized: "\(shortPercent)% short"), pace.runsOutText ]
                        .compactMap { $0 }
                        .joined(separator: " · "))
                        .foregroundStyle(DS.C.textSub)
                }
            }
            .font(.system(size: 11.5, weight: .medium))
            .lineLimit(1)
        }
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(DS.C.text)
                StatusDot(color: statusColor ?? dotColor, size: 8)
            }

            bar(height: 12)

            VStack(spacing: 3) {
                metaLine(left: leftText, right: pace.resetText)
                if let shortPercent = pace.shortPercent {
                    metaLine(left: String(localized: "\(shortPercent)% short"), right: pace.runsOutText ?? "")
                }
            }
        }
    }

    private func metaLine(left: String, right: String) -> some View {
        HStack {
            Text(left)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DS.C.textSub)
            Spacer()
            Text(right)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DS.C.textMuted)
        }
    }

    /// Pace-based: red when spending faster than time allows, green when on/ahead
    /// of pace, gray when there's no live quota.
    private var dotColor: Color {
        guard hasMetric else { return DS.C.textMuted }
        if pace.timeLeftFraction != nil {
            return pace.isBehind ? DS.C.red : DS.C.green
        }
        if quotaLeft >= 0.5 { return DS.C.green }
        if quotaLeft >= 0.25 { return DS.C.yellow }
        return DS.C.red
    }
}

/// Small filled status dot. Green = healthy/active, amber = warning,
/// red = paused/error.
struct StatusDot: View {
    var color: Color
    var size: CGFloat = 6

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Pill status badge: colored dot + label, white background, colored border.
struct StatusBadge: View {
    var text: LocalizedStringKey
    var color: Color

    var body: some View {
        HStack(spacing: 5) {
            StatusDot(color: color, size: 6)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.C.textSub)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(DS.C.surface, in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 1))
    }
}

/// Quiet, icon-only button with a hairline border and accessible label.
struct IconButton: View {
    let systemName: String
    let help: LocalizedStringKey
    var tint: Color = DS.C.textSub
    var border: Color = DS.C.border
    var fill: Color = DS.C.surfaceHigh
    var size: CGFloat = 28
    var isDisabled: Bool = false
    /// Optional ⌘-letter that presses this button while the panel is focused.
    var shortcut: KeyEquivalent? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(
                    fill.opacity(hovering && !isDisabled ? 0.6 : 1.0),
                    in: RoundedRectangle(cornerRadius: DS.R.md, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.R.md, style: .continuous)
                        .stroke(border, lineWidth: 1)
                )
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(isDisabled)
        .modifier(OptionalKeyboardShortcut(key: shortcut))
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

/// Applies ⌘<key> only when one is given.
struct OptionalKeyboardShortcut: ViewModifier {
    let key: KeyEquivalent?

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(key, modifiers: .command)
        } else {
            content
        }
    }
}

/// Very subtle press feedback (no bounce, no color flash).
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.62 : 1.0)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

/// Page title row shared by every tab: optional provider glyph + bold title on
/// the left, controls on the right, fixed height so tabs line up exactly.
struct PanelHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var glyph: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            if let glyph {
                Image(glyph)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .foregroundStyle(DS.C.text)
            }
            Text(title)
                .font(.system(size: DS.Page.titleSize, weight: .bold))
                .foregroundStyle(DS.C.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing()
        }
        .frame(height: DS.Page.headerHeight)
    }
}

/// Remaining ⇄ used toggle for one tool's quota display: an icon-only capsule
/// (↓% = counting down what's left, ↑% = counting up what's used) styled like
/// the compact mode capsule next to it. The tooltip spells the mode out.
struct QuotaDisplayModeToggle: View {
    let mode: QuotaDisplayMode
    let toolName: String
    let onToggle: () -> Void
    @AppStorage(QuotaDisplay.colorfulBarsKey) private var colorfulBars = true

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 1) {
                Image(systemName: mode == .remaining ? "arrow.down" : "arrow.up")
                    .font(.system(size: 10, weight: .bold))
                Image(systemName: "percent")
                    .font(.system(size: 10.5, weight: .bold))
            }
            .foregroundStyle(colorfulBars ? DS.C.usageBlue : DS.C.textSub)
            .frame(width: 34, height: 26)
            .background(DS.C.surface, in: Capsule())
            .overlay(Capsule().stroke(DS.C.border, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .help(mode == .remaining
              ? String(localized: "Showing \(toolName) quota left (counts down from 100%). Click to show quota used.")
              : String(localized: "Showing \(toolName) quota used (counts up from 0%). Click to show quota left."))
        .accessibilityLabel(Text(mode == .remaining
              ? String(localized: "\(toolName) quota shown as percent left. Activate to show percent used.")
              : String(localized: "\(toolName) quota shown as percent used. Activate to show percent left.")))
    }
}
