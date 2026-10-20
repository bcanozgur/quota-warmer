import AppKit
import SwiftUI

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }
}

extension Color {
    /// Hex literal initializer, e.g. `Color(hex: 0xF8FAFC)`.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }

    /// Appearance-aware color: resolved against the view's effective
    /// appearance at draw time, so it follows the app theme (System / Light /
    /// Dark, see `AppearanceMode`) and live system switches with no re-layout.
    init(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: dark, alpha: darkAlpha)
                : NSColor(hex: light, alpha: lightAlpha)
        })
    }
}

/// Design tokens. Tuned to the OpenUsage visual language: a white content
/// surface, a narrow off-white sidebar, hairline borders, navy-near-black
/// titles, slate body text and muted meta text. Every token has a dark twin
/// (neutral graphite surfaces, soft light text) so the panel reads the same in
/// both themes.
enum DS {
    enum C {
        // Surfaces
        static let bg          = Color(light: 0xFFFFFF, dark: 0x1C1D21)   // window + content base
        static let sidebar     = Color(light: 0xF8FAFC, dark: 0x16171A)   // narrow left rail
        static let surface     = Color(light: 0xFFFFFF, dark: 0x25262B)   // cards
        static let surfaceHigh = Color(light: 0xF1F5F9, dark: 0x2F3036)   // quiet button / segmented fill
        static let track       = Color(light: 0xE9EDF2, dark: 0x34363D)   // progress track (no data)
        static let ink         = Color(light: 0x0F172A, dark: 0xF1F3F6)   // selected indicator
        /// Label on a filled accent/danger surface (Warm, prominent buttons).
        /// White reads only 2.9:1 on the muted dark accents, so dark text is used there.
        static let onAccent    = Color(light: 0xFFFFFF, dark: 0x101216)
        /// Pace knob: stays bright on any bar color in both themes.
        static let knob        = Color(light: 0xFFFFFF, dark: 0xE8EAEE)

        // Borders
        static let border      = Color(light: 0xE5E7EB, dark: 0x3A3C43)   // hairline card / divider border
        static let borderSoft  = Color(light: 0xEEF1F5, dark: 0x2F3137)   // very subtle inner divider
        static let borderFocus = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.16, darkAlpha: 0.22)

        // Text
        static let text        = Color(light: 0x0F172A, dark: 0xF1F3F6)   // titles
        static let textSub     = Color(light: 0x475569, dark: 0xB6BCC6)   // body
        static let textMuted   = Color(light: 0x66707F, dark: 0x9298A3)   // meta (WCAG AA 4.5:1)

        // Status — used as text and as dots. Every value is >= 4.5:1 on the
        // card surfaces in its theme (WCAG AA text); status is also conveyed by
        // a label or symbol, never by color alone.
        static let green  = Color(light: 0x11813A, dark: 0x53A96A)
        static let yellow = Color(light: 0xA95D05, dark: 0xCA8B3A)
        static let red    = Color(light: 0xD92525, dark: 0xD5817E)
        static let blue   = Color(light: 0x2563EB, dark: 0x709AD0)

        // Usage bars — claude.ai's light-theme tokens. In dark they are toned
        // down (lower lightness/saturation, same hues) so a full bar doesn't
        // glare against the graphite panel.
        // Each fill keeps >= 3:1 against its own track (WCAG 1.4.11).
        static let usageBlue   = Color(light: 0x2C84DB, dark: 0x5082BD)   // --accent-secondary-100
        static let usageOrange = Color(light: 0xC96E51, dark: 0xBA6E55)   // --accent-main-100
        static let usageRed    = Color(light: 0xB53333, dark: 0xC16565)   // --danger-100
        /// Colored track tint behind a usage bar (a touch lighter in dark).
        static let usageTrackOpacity: Double = 0.16
        /// Single-color bar used when Colorful Quota Bars is off: the original
        /// near-black in light, a soft gray (not glaring white) in dark.
        static let barPlain    = Color(light: 0x0F172A, dark: 0xA9AFBA)

        static func usage(_ level: QuotaUsageLevel) -> Color {
            switch level {
            case .normal:   return usageBlue
            case .warning:  return usageOrange
            case .critical: return usageRed
            }
        }

        /// Per-tool brand accent. Dark variants are muted like the status colors;
        /// Codex indigo is lifted so the pin stays legible on graphite.
        static func accent(_ tool: ProviderID) -> Color { accent(tool.kind) }

        static func accent(_ tool: ToolID) -> Color {
            tool == .claude ? claudeAccent : codexAccent
        }
        /// Busy hours used by both Claude and Codex: between the two accents.
        static let bothAccent = Color(light: 0xC2408A, dark: 0xC583AB)

        /// History tab: one fixed color per tool across every chart — Claude
        /// orange, Codex blue — so a series is recognisable at a glance and
        /// never reads as a usage level.
        static func history(_ tool: ToolID) -> Color {
            tool == .claude ? claudeAccent : historyCodex
        }
        /// History busy hours shared by both tools: between orange and blue.
        static let historyBoth = Color(light: 0x8B5CC7, dark: 0x8E72C4)
        private static let historyCodex = Color(light: 0x2C84DB, dark: 0x4A86CC)
        private static let claudeAccent = Color(light: 0xBA4F0B, dark: 0xD48554)   // Anthropic orange
        private static let codexAccent  = Color(light: 0x613DE6, dark: 0x9C8EDB)   // OpenAI indigo
    }

    // MARK: - Spacing
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
    }

    // MARK: - Radii
    enum R {
        static let sm: CGFloat = 7    // badges / small chips
        static let md: CGFloat = 10   // buttons / inputs
        static let lg: CGFloat = 14   // cards
        static let xl: CGFloat = 18   // outer panel
    }

    // MARK: - Layout
    // The panel is laid out at totalWidth × totalHeight then uniformly
    // scaled by panelScale, so this knob shrinks the whole UI proportionally
    // without any reflow. 0.81 = a 10% more compact panel than the prior 0.90.
    static let panelScale: CGFloat = 0.81
    static let sidebarWidth: CGFloat = 56
    static let contentWidth: CGFloat = 372
    static let totalWidth:   CGFloat = sidebarWidth + contentWidth
    // Fallback height for tabs that scroll (Settings). The overview and tool tabs measure
    // their own content and the panel follows it (see `PanelHeightKey`).
    static let totalHeight: CGFloat = 462

    // MARK: - Page layout
    // Shared by every tab so the title, cards and edges line up when switching.
    enum Page {
        static let top: CGFloat = 12          // content top inset
        static let side: CGFloat = 10         // content left/right inset
        static let bottom: CGFloat = 10       // content bottom inset
        static let spacing: CGFloat = 10      // gap between header / cards
        static let headerHeight: CGFloat = 28
        static let titleSize: CGFloat = 18
        static let cardPadding: CGFloat = 12  // inner padding of content cards
    }

    // MARK: - Typography
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - View modifiers

extension View {
    /// Standard white card with a hairline border.
    func dsCard(radius: CGFloat = DS.R.lg) -> some View {
        self
            .background(DS.C.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(DS.C.border, lineWidth: 1))
    }

    /// Uppercase, letter-spaced section label (e.g. "WINDOW STATUS").
    func dsSectionLabel() -> some View {
        self.font(.system(size: 10, weight: .semibold))
            .foregroundStyle(DS.C.textMuted)
            .tracking(0.7)
            .textCase(.uppercase)
    }
}


/// Natural height of a tab's content, reported up so the panel can size to it —
/// no dead space with no banked resets, no clipping with several.
struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension View {
    func reportsPanelHeight() -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: PanelHeightKey.self, value: geo.size.height)
        })
    }
}
