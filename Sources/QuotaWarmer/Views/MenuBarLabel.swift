import AppKit
import SwiftUI

/// Builds the menu-bar status-item image from `AppState`. Drives the AppKit
/// `NSStatusItem` button (see `AppDelegate`) — we use a plain status item rather
/// than `MenuBarExtra` so the icon supports both a left-click panel and a
/// right-click menu. Both pinned tools are composited into one `NSImage`.
@MainActor
enum MenuBarStatus {
    static func image(for appState: AppState) -> NSImage {
        let items = composeItems(appState)
        let image = items.isEmpty ? fallbackImage(appState) : MenuBarComposer.image(for: items)
        image.isTemplate = false
        return image
    }

    private static func isHealthy(_ appState: AppState) -> Bool {
        guard !appState.globalPassive, !appState.watcherStale else { return false }
        return appState.toolStates.values.allSatisfy { state in
            if !state.isMonitored { return true }
            return state.sourceHealth == .healthy && state.freshness == .fresh
        }
    }

    /// Tools the user has pinned to the menu bar, shown side by side. Order
    /// follows `ToolID.allCases` so the layout is stable.
    private static func visibleTools(_ appState: AppState) -> [ToolID] {
        ToolID.allCases.filter { appState.state(for: $0).menuBarVisible }
    }

    private static func composeItems(_ appState: AppState) -> [MenuBarComposer.Item] {
        visibleTools(appState).map { tool in
            let st = appState.state(for: tool)
            // Dim only when data is expired or unhealthy — stale (5–30min) is
            // recent enough with a 5-minute refresh interval and should not dim.
            let prominent = st.isWarming || (st.isMonitored && st.sourceHealth == .healthy
                && st.freshness != .expired && st.freshness != .unknown)

            let text: String
            if st.isWarming {
                text = "warming"
            } else if st.sessionSettling, let r = st.timeUntilReset {
                // Window just opened; the percentage is a not-yet-settled rollover
                // artifact, so show only the countdown (no misleading "0%").
                text = compactTime(r)
            } else if st.primaryMetric?.isIdleFiveHourWindow == true {
                // No active window yet: the only "reset" is a sliding projection,
                // so show the full remaining percent without a fake countdown that
                // would make a not-yet-started window look active.
                text = "\(Int((st.primaryMetric?.remainingFraction ?? 1) * 100))%"
            } else if let r = st.timeUntilReset {
                text = compactQuotaText(time: r, metric: st.primaryMetric)
            } else if let metric = st.primaryMetric {
                // No live 5h countdown (window depleted/expired/rate-limited): show
                // the 5h remaining percent only. The menu-bar label represents the
                // 5-hour window — never fall back to the weekly window's countdown
                // here, which spans days and misrepresents the 5h slot as lasting
                // more than five hours.
                text = "\(Int(metric.remainingFraction * 100))%"
            } else {
                // Auth/setup problems are conveyed by the status dot and the
                // popover. A raw "login" label in the system menu bar looks like
                // an app defect, especially when another tool still has live data.
                text = ""
            }

            return MenuBarComposer.Item(
                assetName: tool == .claude ? "ClaudeCode" : "Codex",
                dotColor: nsStatusColor(for: st, appState: appState),
                text: text,
                // Neutral menu-bar-white text (the colored status dot conveys
                // state), not a saturated color.
                textColor: .white,
                dimmed: !prominent
            )
        }
    }

    private static func compactTime(_ secs: TimeInterval) -> String {
        let total = Int(secs)
        let d = total / 86_400
        let h = (total % 86_400) / 3600
        let m = (total % 3600) / 60
        if d > 0 { return "\(d)d\(h)h" }
        return h > 0 ? "\(h)h\(String(format: "%02d", m))m" : "\(m)m"
    }

    private static func compactQuotaText(time: TimeInterval, metric: QuotaMetric?) -> String {
        let percent = Int((metric?.remainingFraction ?? 0) * 100)
        return "\(compactTime(time)) - \(percent)%"
    }

    private static func nsStatusColor(for state: ToolState, appState: AppState) -> NSColor {
        // Off / globally-paused tools get a neutral gray dot so they no longer
        // look like an error (which is red).
        if appState.globalPassive || !state.isMonitored { return .systemGray }
        if state.sourceHealth == .healthy && state.freshness == .fresh {
            return state.mode == .monitor ? .systemBlue : .systemGreen
        }
        if state.sourceHealth == .authFailure || state.sourceHealth == .unavailable { return .systemRed }
        return .systemYellow
    }

    /// Shown when no tool is pinned to the menu bar: a flame glyph plus an
    /// overall-health dot, so the status item is never blank.
    private static func fallbackImage(_ appState: AppState) -> NSImage {
        let healthy = isHealthy(appState)
        let size = NSSize(width: 21, height: 18)
        return NSImage(size: size, flipped: false) { _ in
            let glyphRect = NSRect(x: 0, y: 1, width: 14, height: 14)
            if let flame = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: nil) {
                let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                let img = flame.withSymbolConfiguration(cfg) ?? flame
                img.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1,
                         respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
                NSColor(calibratedRed: 0.90, green: 0.38, blue: 0.05, alpha: 1).setFill()
                glyphRect.fill(using: .sourceAtop)
            }
            let dot: CGFloat = 6
            let dotRect = NSRect(x: glyphRect.maxX + 1, y: (size.height - dot) / 2, width: dot, height: dot)
            (healthy ? NSColor.systemGreen : NSColor.systemRed).setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
    }
}

/// Draws one or more provider glyphs (white, with a colored status dot) plus
/// their quota text into a single NSImage for use as the menu-bar label.
private enum MenuBarComposer {
    struct Item {
        let assetName: String
        let dotColor: NSColor
        let text: String
        let textColor: NSColor
        let dimmed: Bool
    }

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    private static let height: CGFloat = 18
    private static let glyph: CGFloat = 15
    private static let glyphGap: CGFloat = 3
    private static let itemGap: CGFloat = 8

    static func image(for items: [Item]) -> NSImage {
        var widths: [CGFloat] = []
        var total: CGFloat = 0
        for (index, item) in items.enumerated() {
            var w = glyph
            let tw = textWidth(item.text)
            if tw > 0 { w += glyphGap + tw }
            widths.append(w)
            total += w
            if index < items.count - 1 { total += itemGap }
        }
        total = max(total, glyph)

        let size = NSSize(width: ceil(total), height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            var x: CGFloat = 0
            for (index, item) in items.enumerated() {
                draw(item, at: x)
                x += widths[index] + itemGap
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func textWidth(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func draw(_ item: Item, at originX: CGFloat) {
        let alpha: CGFloat = item.dimmed ? 0.6 : 1.0
        let logoRect = NSRect(x: originX, y: (height - glyph) / 2, width: glyph, height: glyph)

        if let source = NSImage(named: item.assetName) {
            source.draw(
                in: logoRect,
                from: .zero,
                operation: .sourceOver,
                fraction: alpha,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            // Recolor the monochrome glyph to white, preserving its alpha.
            NSColor.white.withAlphaComponent(alpha).setFill()
            logoRect.fill(using: .sourceAtop)
        }

        // Status dot at the glyph's bottom-right corner.
        let dot: CGFloat = 5.5
        let dotRect = NSRect(x: logoRect.maxX - dot + 1, y: logoRect.minY - 0.5, width: dot, height: dot)
        item.dotColor.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        NSColor.controlBackgroundColor.withAlphaComponent(0.9 * alpha).setStroke()
        let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: -0.5, dy: -0.5))
        ring.lineWidth = 0.75
        ring.stroke()

        guard !item.text.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: item.textColor.withAlphaComponent(alpha)
        ]
        let textSize = (item.text as NSString).size(withAttributes: attrs)
        let textY = (height - textSize.height) / 2
        (item.text as NSString).draw(
            at: NSPoint(x: logoRect.maxX + glyphGap, y: textY),
            withAttributes: attrs
        )
    }
}
