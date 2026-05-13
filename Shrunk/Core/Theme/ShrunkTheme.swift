import SwiftUI

// MARK: - Color hex initializer

extension Color {
    init(hex: String) {
        let cleaned = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        var raw: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&raw)
        let a, r, g, b: UInt64
        switch cleaned.count {
        case 6:
            (a, r, g, b) = (255, (raw >> 16) & 0xFF, (raw >> 8) & 0xFF, raw & 0xFF)
        case 8:
            (a, r, g, b) = ((raw >> 24) & 0xFF, (raw >> 16) & 0xFF, (raw >> 8) & 0xFF, raw & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Brand palette

extension Color {
    static let shrunkRed       = Color(hex: "E24B4A")
    static let shrunkRedLight  = Color(hex: "FCEBEB")
    static let shrunkRedDark   = Color(hex: "791F1F")
    static let shrunkRedDeep   = Color(hex: "B0302F")

    static let verdictGood     = Color(hex: "1D9E75")
    static let verdictGoodDeep = Color(hex: "157852")
    static let verdictGoodTint = Color(hex: "E8F5EE")
    static let verdictWarn     = Color(hex: "EF9F27")
    static let verdictWarnDeep = Color(hex: "B2700B")
    static let verdictWarnTint = Color(hex: "FDF1DE")
    static let verdictBad      = Color(hex: "E24B4A")

    // Neutrals — refined: warmer paper background, more depth in inks
    static let ink             = Color(hex: "0E0E11")
    static let inkSubtle       = Color(hex: "32343B")
    static let smoke           = Color(hex: "6B7280")
    static let smokeSoft       = Color(hex: "9CA3AF")
    static let mist            = Color(hex: "F4F4F5")
    static let paper           = Color(hex: "FAFAF7")    // warm off-white app background
    static let surface         = Color.white
    static let border          = Color(hex: "E8E8EA")
    static let borderSoft      = Color(hex: "F0F0F2")
}

// MARK: - Brand gradients

extension LinearGradient {
    static var shrunkRedDiagonal: LinearGradient {
        LinearGradient(
            colors: [Color.shrunkRed, Color.shrunkRedDeep],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    static var verdictGoodDiagonal: LinearGradient {
        LinearGradient(
            colors: [Color.verdictGood, Color.verdictGoodDeep],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    static var verdictWarnDiagonal: LinearGradient {
        LinearGradient(
            colors: [Color.verdictWarn, Color.verdictWarnDeep],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    static var paperFade: LinearGradient {
        LinearGradient(
            colors: [Color.paper, Color.mist],
            startPoint: .top, endPoint: .bottom
        )
    }
}

// MARK: - Theme tokens

enum ShrunkTheme {
    enum Spacing {
        static let xs: CGFloat   = 4
        static let sm: CGFloat   = 8
        static let md: CGFloat   = 16
        static let lg: CGFloat   = 24
        static let xl: CGFloat   = 32
        static let xxl: CGFloat  = 48
        static let huge: CGFloat = 72
    }

    enum Radius {
        static let xs: CGFloat = 6
        static let sm: CGFloat = 10
        static let md: CGFloat = 14
        static let lg: CGFloat = 20
        static let xl: CGFloat = 28
        static let pill: CGFloat = 999
    }

    enum FontSize {
        static let hero: CGFloat     = 64
        static let display: CGFloat  = 32
        static let largeTitle: CGFloat = 28
        static let title: CGFloat    = 22
        static let headline: CGFloat = 18
        static let body: CGFloat     = 16
        static let callout: CGFloat  = 14
        static let caption: CGFloat  = 12
        static let micro: CGFloat    = 11
        static let nano: CGFloat     = 10
    }

    /// Three-tier elevation system. Use these instead of plain borders for cards
    /// — borders alone read as "drawn", shadows read as "real".
    enum Elevation {
        struct Shadow {
            let color: Color
            let radius: CGFloat
            let x: CGFloat
            let y: CGFloat
        }

        // Whisper: barely-there hairline. For inline chips, list rows.
        static let whisper = Shadow(color: Color.black.opacity(0.04), radius: 1, x: 0, y: 1)

        // Card: standard elevated surface.
        static let card = Shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)

        // Float: hovering element (paywall hero, key CTAs).
        static let float = Shadow(color: Color.black.opacity(0.10), radius: 24, x: 0, y: 8)
    }
}

// MARK: - Typography

extension Font {
    /// Massive hero number used on Result and Browse cards. This IS the brand voice.
    static let shrunkHero        = Font.system(size: ShrunkTheme.FontSize.hero,       weight: .heavy,     design: .rounded)

    static let shrunkDisplay     = Font.system(size: ShrunkTheme.FontSize.display,    weight: .bold,      design: .default)
    static let shrunkLargeTitle  = Font.system(size: ShrunkTheme.FontSize.largeTitle, weight: .bold,      design: .default)
    static let shrunkTitle       = Font.system(size: ShrunkTheme.FontSize.title,      weight: .bold,      design: .default)
    static let shrunkHeadline    = Font.system(size: ShrunkTheme.FontSize.headline,   weight: .semibold,  design: .default)
    static let shrunkBody        = Font.system(size: ShrunkTheme.FontSize.body,       weight: .regular,   design: .default)
    static let shrunkCallout     = Font.system(size: ShrunkTheme.FontSize.callout,    weight: .regular,   design: .default)
    static let shrunkCaption     = Font.system(size: ShrunkTheme.FontSize.caption,    weight: .regular,   design: .default)

    /// Monospaced numerics — keeps digits aligned so "5.9¢ → 6.8¢" reads as a comparison, not wobbling text.
    static let shrunkMonoHero    = Font.system(size: ShrunkTheme.FontSize.hero,       weight: .heavy,     design: .monospaced)
    static let shrunkMonoDisplay = Font.system(size: ShrunkTheme.FontSize.display,    weight: .bold,      design: .monospaced)
    static let shrunkMonoBig     = Font.system(size: 36,                              weight: .bold,      design: .monospaced)
    static let shrunkMonoNumber  = Font.system(size: ShrunkTheme.FontSize.body,       weight: .semibold,  design: .monospaced)
    static let shrunkMonoSmall   = Font.system(size: ShrunkTheme.FontSize.callout,    weight: .medium,    design: .monospaced)

    /// Section labels — uppercase tracked. The little voice of the system.
    static let shrunkLabel       = Font.system(size: ShrunkTheme.FontSize.micro,      weight: .heavy,     design: .default)
}

// MARK: - View modifiers

extension View {
    /// Apply one of the elevation tokens. Use this instead of writing
    /// `.shadow(...)` directly — keeps the depth language consistent.
    func shrunkElevation(_ shadow: ShrunkTheme.Elevation.Shadow) -> some View {
        self.shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
    }

    /// Standard card surface: white fill, soft shadow, subtle border.
    func shrunkCard(radius: CGFloat = ShrunkTheme.Radius.lg, padding: CGFloat? = ShrunkTheme.Spacing.md) -> some View {
        modifier(ShrunkCardModifier(radius: radius, padding: padding))
    }

    /// Section label — uppercase, tracked, smoke-colored. One-liner for consistency.
    func shrunkSectionLabel() -> some View {
        self.font(.shrunkLabel)
            .tracking(0.8)
            .foregroundStyle(Color.smoke)
            .textCase(.uppercase)
    }
}

private struct ShrunkCardModifier: ViewModifier {
    let radius: CGFloat
    let padding: CGFloat?

    func body(content: Content) -> some View {
        content
            .padding(padding ?? 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.borderSoft, lineWidth: 0.5)
            )
            .shrunkElevation(ShrunkTheme.Elevation.card)
    }
}
