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
        /// Pace knob: stays bright on any bar color in both themes.
        static let knob        = Color(light: 0xFFFFFF, dark: 0xE8EAEE)

        // Borders
        static let border      = Color(light: 0xE5E7EB, dark: 0x3A3C43)   // hairline card / divider border
        static let borderSoft  = Color(light: 0xEEF1F5, dark: 0x2F3137)   // very subtle inner divider
        static let borderFocus = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.16, darkAlpha: 0.22)

        // Text
        static let text        = Color(light: 0x0F172A, dark: 0xF1F3F6)   // titles
        static let textSub     = Color(light: 0x475569, dark: 0xB6BCC6)   // body
        static let textMuted   = Color(light: 0x94A3B8, dark: 0x7D8491)   // meta

        // Status — dark variants are muted to sit with the toned-down usage
        // colors while keeping enough contrast on graphite.
        static let green  = Color(light: 0x16A34A, dark: 0x3E9E58)
        static let yellow = Color(light: 0xD97706, dark: 0xC98A38)
        static let red    = Color(light: 0xDC2626, dark: 0xC65550)
        static let blue   = Color(light: 0x2563EB, dark: 0x4A7FC4)

        // Usage bars — claude.ai's light-theme tokens. In dark they are toned
        // down (lower lightness/saturation, same hues) so a full bar doesn't
        // glare against the graphite panel.
        static let usageBlue   = Color(light: 0x2C84DB, dark: 0x3A73B5)   // --accent-secondary-100
        static let usageOrange = Color(light: 0xD97757, dark: 0xBA6E55)   // --accent-main-100
        static let usageRed    = Color(light: 0xB53333, dark: 0xB54848)   // --danger-100
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
        static func accent(_ tool: ToolID) -> Color {
            tool == .claude ? claudeAccent : codexAccent
        }
        private static let claudeAccent = Color(light: 0xE6610D, dark: 0xCB6A2F)   // Anthropic orange
        private static let codexAccent  = Color(light: 0x613DE6, dark: 0x7F6CD0)   // OpenAI indigo
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
    // Sized so the overview (header + status card + both provider cards) fits with no dead
    // space below; longer tabs (Settings) scroll.
    static let totalHeight: CGFloat = 436

    // MARK: - Page layout
    // Shared by every tab so the title, cards and edges line up when switching.
    enum Page {
        static let top: CGFloat = 24          // content top inset
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
