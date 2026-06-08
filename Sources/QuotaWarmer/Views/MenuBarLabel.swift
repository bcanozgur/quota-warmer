import AppKit
import SwiftUI

struct MenuBarLabel: View {
    @EnvironmentObject var appState: AppState

    private var isHealthy: Bool {
        guard !appState.globalPassive, !appState.watcherStale else { return false }
        return appState.toolStates.values.allSatisfy { state in
            if !state.isMonitored { return true }
            return state.sourceHealth == .healthy && state.freshness == .fresh
        }
    }

    @ViewBuilder
    var body: some View {
        // macOS renders a MenuBarExtra label's content as a *single* status-item
        // view and only the first child of a multi-element layout shows up. So
        // both pinned tools are composited into one NSImage, which is then shown
        // as a single Image — guaranteed to render at full width.
        // (Per-second ticking is driven by AppState's UI refresh timer, which
        // pokes this view; TimelineView doesn't render as a menu-bar label.)
        let items = composeItems()
        if items.isEmpty {
            fallbackLabel
                .frame(height: 16)
                .fixedSize()
        } else {
            Image(nsImage: MenuBarComposer.image(for: items))
                .renderingMode(.original)
        }
    }

    /// Tools the user has pinned to the menu bar, shown side by side. Order
    /// follows `ToolID.allCases` so the layout is stable.
    private var visibleTools: [ToolID] {
        ToolID.allCases.filter { appState.state(for: $0).menuBarVisible }
    }

    @ViewBuilder
    private var fallbackLabel: some View {
        HStack(spacing: 2) {
            Image(systemName: "flame.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DS.C.accent(.claude))
            Circle()
                .fill(isHealthy ? DS.C.green : DS.C.red)
                .frame(width: 5.5, height: 5.5)
        }
    }

    private func composeItems() -> [MenuBarComposer.Item] {
        visibleTools.map { tool in
            let st = appState.state(for: tool)
            let prominent = st.isWarming || (st.isMonitored && st.sourceHealth == .healthy && st.freshness == .fresh)

            let text: String
            if st.authStatus == .failed || st.authStatus == .missing {
                text = "login"
            } else if st.isWarming {
                text = "warming"
            } else if let r = st.timeUntilReset {
                text = compactQuotaText(time: r, metric: st.primaryMetric)
            } else if let metric = st.primaryMetric {
                text = "\(Int(metric.remainingFraction * 100))%"
            } else {
                text = ""
            }

            return MenuBarComposer.Item(
                assetName: tool == .claude ? "ClaudeCode" : "Codex",
                dotColor: nsStatusColor(for: st),
                text: text,
                // Match the prior look: neutral menu-bar-white text (the
                // colored status dot conveys state), not a saturated color.
                textColor: .white,
                dimmed: !prominent
            )
        }
    }

    private func compactTime(_ secs: TimeInterval) -> String {
        let total = Int(secs)
        let d = total / 86_400
        let h = (total % 86_400) / 3600
        let m = (total % 3600) / 60
        if d > 0 { return "\(d)d\(h)h" }
        return h > 0 ? "\(h)h\(String(format: "%02d", m))m" : "\(m)m"
    }

    private func compactQuotaText(time: TimeInterval, metric: QuotaMetric?) -> String {
        let percent = Int((metric?.remainingFraction ?? 0) * 100)
        return "\(compactTime(time)) - \(percent)%"
    }

    private func nsStatusColor(for state: ToolState) -> NSColor {
        // Off / globally-paused tools get a neutral gray dot so they no longer
        // look like an error (which is red).
        if appState.globalPassive || !state.isMonitored { return .systemGray }
        if state.sourceHealth == .healthy && state.freshness == .fresh { return .systemGreen }
        if state.sourceHealth == .authFailure || state.sourceHealth == .unavailable { return .systemRed }
        return .systemYellow
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
