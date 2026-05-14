import SwiftUI

enum DS {
    // MARK: - Colors (clean light mode — white/black)
    enum C {
        // Backgrounds
        static let bg          = Color(white: 1.00)          // pure white
        static let surface     = Color(white: 0.965)         // #f7f7f7
        static let surfaceHigh = Color(white: 0.935)         // #eeeeee

        // Borders
        static let border      = Color.black.opacity(0.08)
        static let borderFocus = Color.black.opacity(0.16)

        // Text
        static let text        = Color(white: 0.11)          // #1c1c1e near-black
        static let textSub     = Color(white: 0.43)          // #6e6e73
        static let textMuted   = Color(white: 0.64)          // #a3a3a3

        // Semantic
        static let green  = Color(red: 0.13, green: 0.69, blue: 0.30)
        static let yellow = Color(red: 0.82, green: 0.60, blue: 0.05)
        static let red    = Color(red: 0.86, green: 0.20, blue: 0.20)
        static let blue   = Color(red: 0.20, green: 0.46, blue: 0.95)

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
            .background(DS.C.bg, in: RoundedRectangle(cornerRadius: DS.R.md))
            .overlay(RoundedRectangle(cornerRadius: DS.R.md).stroke(DS.C.border, lineWidth: 1))
    }

    func dsLabel() -> some View {
        self.font(.system(size: 9, weight: .semibold))
            .foregroundStyle(DS.C.textMuted)
            .tracking(0.4)
    }
}
