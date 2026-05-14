import SwiftUI

enum DS {
    // MARK: - Colors (openusage-inspired macOS native dark)
    enum C {
        // Backgrounds — Apple's exact system dark surface colors
        static let bg          = Color(red: 0.110, green: 0.110, blue: 0.118)  // #1c1c1e
        static let surface     = Color(red: 0.165, green: 0.165, blue: 0.173)  // #2a2a2c
        static let surfaceHigh = Color(red: 0.173, green: 0.173, blue: 0.181)  // #2c2c2e

        // Borders
        static let border      = Color(white: 1, opacity: 0.08)
        static let borderFocus = Color(white: 1, opacity: 0.15)

        // Text hierarchy
        static let text        = Color(red: 0.929, green: 0.929, blue: 0.929)  // #ededed
        static let textSub     = Color(white: 0.533)                            // #888
        static let textMuted   = Color(white: 0.380)                            // #616

        // Semantic
        static let green  = Color(red: 0.22, green: 0.87, blue: 0.45)
        static let yellow = Color(red: 0.97, green: 0.80, blue: 0.25)
        static let red    = Color(red: 0.95, green: 0.37, blue: 0.37)
        static let blue   = Color(red: 0.40, green: 0.62, blue: 1.00)

        static func accent(_ tool: ToolID) -> Color {
            tool == .claude
                ? Color(red: 0.95, green: 0.46, blue: 0.13)   // Anthropic orange
                : Color(red: 0.45, green: 0.32, blue: 0.96)   // OpenAI indigo
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
        static let sm: CGFloat = 5
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
    }

    // MARK: - Layout
    static let sidebarWidth: CGFloat = 48
    static let contentWidth: CGFloat = 300
    static let totalWidth:   CGFloat = sidebarWidth + contentWidth

    // MARK: - Typography
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - View modifiers

extension View {
    func dsCard() -> some View {
        self
            .background(DS.C.surface, in: RoundedRectangle(cornerRadius: DS.R.md))
            .overlay(RoundedRectangle(cornerRadius: DS.R.md).stroke(DS.C.border, lineWidth: 1))
    }

    func dsLabel() -> some View {
        self.font(.system(size: 9, weight: .semibold))
            .foregroundStyle(DS.C.textMuted)
            .tracking(0.5)
    }
}
