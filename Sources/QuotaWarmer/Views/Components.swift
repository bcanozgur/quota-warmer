import SwiftUI

// Reusable UI primitives shared across the in-app screens. Tuned to the
// OpenUsage visual language: slim usage bars, muted status dots/badges, and
// quiet native-feeling controls with very subtle hover/press states.

/// Slim, gradient-free usage bar: light track + near-black fill. The fill shows
/// how much quota is left. An optional `thumbFraction` draws a slider-style knob
/// marking how much of the window's *time* remains — when the knob sits ahead of
/// the fill, quota is being spent faster than time (the "behind pace" warning).
struct UsageBar: View {
    var fraction: Double
    var refreshing: Bool = false
    var height: CGFloat = 8
    var fill: Color = DS.C.ink
    var thumbFraction: Double? = nil

    private func clamp(_ value: Double) -> CGFloat { CGFloat(min(max(value, 0), 1)) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fillW = max(0, w * clamp(fraction))
            ZStack(alignment: .leading) {
                Capsule().fill(DS.C.track)
                Capsule()
                    .fill(fill)
                    .frame(width: fillW)
                if refreshing {
                    Capsule()
                        .fill(.white.opacity(0.22))
                        .frame(width: w * 0.25)
                        .offset(x: w * 0.25)
                }
                if let thumbFraction {
                    let thumbW: CGFloat = 5
                    Capsule()
                        .fill(DS.C.surface)
                        .overlay(Capsule().stroke(DS.C.textMuted, lineWidth: 1))
                        .frame(width: thumbW, height: height + 5)
                        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                        .offset(x: min(max(w * clamp(thumbFraction) - thumbW / 2, 0), w - thumbW))
                }
            }
        }
        .frame(height: height)
    }
}

/// Compact human duration: `46m`, `3h 30m`, `2d 8h`.
func quotaDurationText(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    if seconds < 86_400 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
    return "\(seconds / 86_400)d \((seconds % 86_400) / 3600)h"
}

/// Pace model behind the usage bars: compares quota left against time left in the
/// window. When more time than quota remains, the quota will empty before the
/// window resets — we surface how far "behind" it is and a projected run-out time.
enum QuotaPace {
    struct Result {
        var timeLeftFraction: Double?   // thumb position; nil when no reset is known
        var resetText: String           // "Resets in 3h 30m" (or a fallback)
        var shortPercent: Int?          // deficit vs pace, only when behind
        var runsOutText: String?        // "Runs out in 46m", only when behind
        var isBehind: Bool { shortPercent != nil }
    }

    static func compute(
        quotaLeft: Double,
        resetAt: Date?,
        windowDuration: TimeInterval,
        now: Date,
        fallbackResetText: String
    ) -> Result {
        guard let resetAt else {
            return Result(timeLeftFraction: nil, resetText: fallbackResetText,
                          shortPercent: nil, runsOutText: nil)
        }
        let timeRemaining = max(0, resetAt.timeIntervalSince(now))
        let timeLeftFraction = min(max(timeRemaining / windowDuration, 0), 1)
        let resetText = "Resets in \(quotaDurationText(Int(timeRemaining)))"

        // Behind pace: more of the window's time remains than quota does, so at
        // the current burn rate the quota empties before the window resets.
        guard timeLeftFraction > quotaLeft + 0.01 else {
            return Result(timeLeftFraction: timeLeftFraction, resetText: resetText,
                          shortPercent: nil, runsOutText: nil)
        }
        let shortPercent = Int(round((timeLeftFraction - quotaLeft) * 100))
        let elapsed = windowDuration - timeRemaining
        let quotaUsed = max(0, 1 - quotaLeft)
        var runsOutText: String?
        if elapsed > 0, quotaUsed > 0 {
            let secondsToRunout = quotaLeft / (quotaUsed / elapsed)
            if secondsToRunout.isFinite, secondsToRunout >= 0, secondsToRunout < timeRemaining {
                runsOutText = "Runs out in \(quotaDurationText(Int(secondsToRunout)))"
            }
        }
        return Result(timeLeftFraction: timeLeftFraction, resetText: resetText,
                      shortPercent: shortPercent, runsOutText: runsOutText)
    }
}

/// One quota window block: a "Session"/"Weekly" title with a pace status dot, a
/// wide usage bar with the time-pace knob, and one or two meta lines
/// (`X% left` / `Resets in …`, plus `N% short` / `Runs out in …` when behind).
struct QuotaWindowRow: View {
    let title: String
    let hasMetric: Bool
    let quotaLeft: Double
    let leftText: String
    let pace: QuotaPace.Result
    var refreshing: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(DS.C.text)
                StatusDot(color: dotColor, size: 8)
            }

            UsageBar(fraction: quotaLeft, refreshing: refreshing, height: 12,
                     thumbFraction: pace.timeLeftFraction)

            VStack(spacing: 3) {
                metaLine(left: leftText, right: pace.resetText)
                if let shortPercent = pace.shortPercent {
                    metaLine(left: "\(shortPercent)% short", right: pace.runsOutText ?? "")
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
    }
}

/// Pill status badge: colored dot + label, white background, colored border.
struct StatusBadge: View {
    var text: String
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
    let help: String
    var tint: Color = DS.C.textSub
    var border: Color = DS.C.border
    var fill: Color = DS.C.surfaceHigh
    var size: CGFloat = 28
    var isDisabled: Bool = false
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
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(Text(help))
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
