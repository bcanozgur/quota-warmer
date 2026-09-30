import Foundation

/// Whether quota is presented as what's left (bar drains from 100% toward 0%)
/// or what's been spent (bar fills from 0% toward 100%). Display-only: warm-up
/// gating, dedup keys and pace math always work on the remaining fraction.
enum QuotaDisplayMode: String, CaseIterable {
    case remaining
    case used

    var toggled: QuotaDisplayMode { self == .remaining ? .used : .remaining }

    static func stored(for tool: ToolID, defaults: UserDefaults = .standard) -> QuotaDisplayMode {
        defaults.string(forKey: defaultsKey(for: tool)).flatMap(QuotaDisplayMode.init(rawValue:)) ?? .remaining
    }

    static func defaultsKey(for tool: ToolID) -> String { "quotaDisplayMode.\(tool.rawValue)" }
}

/// Claude-style severity of a quota window, driven by how much has been used.
/// Independent of the display mode, so flipping the mode never recolors a bar.
enum QuotaUsageLevel: Equatable {
    case normal     // blue
    case warning    // orange
    case critical   // red

    /// Whole used-percent thresholds (Int, so 0.7 * 100 float error can't
    /// push exactly 50% into the wrong band).
    static let warningUsedPercent = 50
    static let criticalUsedPercent = 80

    init(remainingFraction: Double) {
        // Compare on whole percents so the color always agrees with the number
        // shown next to the bar (50% used is orange, 49% is still blue).
        let usedPercent = QuotaDisplay.usedPercent(remainingFraction: remainingFraction)
        if usedPercent >= Self.criticalUsedPercent {
            self = .critical
        } else if usedPercent >= Self.warningUsedPercent {
            self = .warning
        } else {
            self = .normal
        }
    }
}

/// Pure presentation math for quota bars and the menu-bar label, kept free of
/// SwiftUI/AppKit so the regression script can exercise it directly.
enum QuotaDisplay {
    /// Settings → "Colorful Quota Bars". On (default): bars are blue / orange /
    /// red by usage. Off: the original single-color (ink) bars.
    static let colorfulBarsKey = "colorfulQuotaBars"

    /// Severity to color a row with, or nil for the plain single-color style.
    /// A row with no data, or one still settling after a rollover, stays in the
    /// calm `.normal` band rather than flashing a warning color.
    static func colorLevel(remainingFraction: Double, hasMetric: Bool, settling: Bool, colorful: Bool) -> QuotaUsageLevel? {
        guard colorful else { return nil }
        guard hasMetric, !settling else { return .normal }
        return QuotaUsageLevel(remainingFraction: remainingFraction)
    }

    /// Whole percent left. Truncates (0.999 → 99%) so a window is never shown
    /// as fully available until it really is. The tiny epsilon absorbs binary
    /// float error: 1 - 0.29 is 0.71000…, but 0.29 * 100 is 28.999…, and plain
    /// truncation would show a provider's exact 29% as 28%.
    static func remainingPercent(remainingFraction: Double) -> Int {
        let clamped = min(max(remainingFraction, 0), 1)
        return min(100, Int((clamped * 100 + 1e-9).rounded(.down)))
    }

    /// Whole percent used, defined as the complement of `remainingPercent` so the
    /// two modes always add up to exactly 100.
    static func usedPercent(remainingFraction: Double) -> Int {
        100 - remainingPercent(remainingFraction: remainingFraction)
    }

    static func percent(remainingFraction: Double, mode: QuotaDisplayMode) -> Int {
        mode == .remaining
            ? remainingPercent(remainingFraction: remainingFraction)
            : usedPercent(remainingFraction: remainingFraction)
    }

    /// Bar fill in 0...1 for the chosen mode. With no metric the bar is empty in
    /// both modes — "used" must not paint a full bar just because nothing is known.
    static func barFraction(remainingFraction: Double, hasMetric: Bool, mode: QuotaDisplayMode) -> Double {
        guard hasMetric else { return 0 }
        let remaining = min(max(remainingFraction, 0), 1)
        return mode == .remaining ? remaining : 1 - remaining
    }

    /// Pace knob position. It marks time *left* when the bar shows quota left,
    /// and time *elapsed* when the bar shows quota used, so in both modes "the
    /// bar is on the wrong side of the knob" means behind pace.
    static func thumbFraction(timeLeftFraction: Double?, mode: QuotaDisplayMode) -> Double? {
        guard let timeLeftFraction else { return nil }
        let clamped = min(max(timeLeftFraction, 0), 1)
        return mode == .remaining ? clamped : 1 - clamped
    }

    static func suffix(for mode: QuotaDisplayMode) -> String {
        mode == .remaining ? "left" : "used"
    }

    /// Row label: `83% left` / `17% used`, or the `last known` variant.
    static func quotaText(remainingFraction: Double?, isLive: Bool, mode: QuotaDisplayMode) -> String {
        guard let remainingFraction else { return "-- \(suffix(for: mode))" }
        let value = percent(remainingFraction: remainingFraction, mode: mode)
        return isLive ? "\(value)% \(suffix(for: mode))" : "\(value)% last known"
    }

    /// Menu-bar countdown: `3h05m`, `42m`, `2d4h`.
    static func compactTime(_ secs: TimeInterval) -> String {
        let total = max(0, Int(secs))
        let d = total / 86_400
        let h = (total % 86_400) / 3600
        let m = (total % 3600) / 60
        if d > 0 { return "\(d)d\(h)h" }
        return h > 0 ? "\(h)h\(String(format: "%02d", m))m" : "\(m)m"
    }

    /// Inputs of the menu-bar text for one tool (the 5-hour window only).
    struct MenuBarInput {
        var isWarming = false
        var sessionSettling = false
        var timeUntilReset: TimeInterval?
        var isIdleFiveHourWindow = false
        var primaryWindowRolledOver = false
        /// nil when there is no 5h metric at all.
        var remainingFraction: Double?
    }

    static func menuBarText(_ input: MenuBarInput, mode: QuotaDisplayMode) -> String {
        if input.isWarming { return "warming" }
        if input.sessionSettling, let reset = input.timeUntilReset {
            // Window just opened; the percentage is a not-yet-settled rollover
            // artifact, so show only the countdown (no misleading "0%").
            return compactTime(reset)
        }
        if input.isIdleFiveHourWindow {
            // No active window yet: quota is full, and the only "reset" is a
            // sliding projection, so no countdown.
            return "\(percent(remainingFraction: input.remainingFraction ?? 1, mode: mode))%"
        }
        if let reset = input.timeUntilReset {
            let value = percent(remainingFraction: input.remainingFraction ?? 0, mode: mode)
            return "\(compactTime(reset)) - \(value)%"
        }
        if input.primaryWindowRolledOver {
            // The known reset passed while polling was blocked: the window rolled
            // over and quota is (approximately) restored.
            return "~\(percent(remainingFraction: 1, mode: mode))%"
        }
        if let remaining = input.remainingFraction {
            return "\(percent(remainingFraction: remaining, mode: mode))%"
        }
        // Auth/setup problems are conveyed by the status dot and the popover.
        return ""
    }
}
