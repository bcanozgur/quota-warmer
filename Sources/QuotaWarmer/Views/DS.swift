import SwiftUI

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
}

/// Design tokens. Tuned to the OpenUsage visual language: a white content
/// surface, a narrow off-white sidebar, hairline borders, navy-near-black
/// titles, slate body text, muted meta text, and slim near-black usage bars.
enum DS {
    enum C {
        // Surfaces
        static let bg          = Color(hex: 0xFFFFFF)   // window + content base (white)
        static let sidebar     = Color(hex: 0xF8FAFC)   // narrow left rail
        static let surface     = Color(hex: 0xFFFFFF)   // cards
        static let surfaceHigh = Color(hex: 0xF1F5F9)   // quiet button / segmented fill (slate-100)
        static let track       = Color(hex: 0xE9EDF2)   // progress track
        static let ink         = Color(hex: 0x0F172A)   // near-black navy: bar fill, selected indicator

        // Borders
        static let border      = Color(hex: 0xE5E7EB)   // hairline card / divider border
        static let borderSoft  = Color(hex: 0xEEF1F5)   // very subtle inner divider
        static let borderFocus = Color.black.opacity(0.16)

        // Text
        static let text        = Color(hex: 0x0F172A)   // titles (navy near-black)
        static let textSub     = Color(hex: 0x475569)   // body (slate-600)
        static let textMuted   = Color(hex: 0x94A3B8)   // meta (slate-400)

        // Status
        static let green  = Color(hex: 0x16A34A)
        static let yellow = Color(hex: 0xD97706)
        static let red    = Color(hex: 0xDC2626)
        static let blue   = Color(hex: 0x2563EB)

        /// Per-tool brand accent. Kept as-is to preserve product identity.
        static func accent(_ tool: ToolID) -> Color {
            tool == .claude
                ? Color(red: 0.90, green: 0.38, blue: 0.05)   // Anthropic orange
                : Color(red: 0.38, green: 0.24, blue: 0.90)   // OpenAI indigo
        }
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
    static let totalHeight: CGFloat = 560

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
