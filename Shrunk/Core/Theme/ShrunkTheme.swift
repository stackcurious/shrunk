import SwiftUI
import UIKit

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

// MARK: - Trait-resolved colours

extension Color {
    /// A light/dark pair resolved per trait collection. SwiftUI's `Color(hex:)`
    /// is a fixed sRGB value, so anything defined that way is frozen in one
    /// appearance; this routes through `UIColor`'s dynamic provider instead.
    static func dynamic(light: String, dark: String) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
    }
}

// MARK: - Brand palette
//
// Two rules, both from the native-UI spec (§3):
//   1. Brand red `#E24B4A` is the app tint and does not move between schemes.
//   2. Verdict colour *meaning* is fixed (red = shrink, amber = minor, green =
//      unchanged/grew) but the actual values adapt, so a wash that reads as a
//      pale tint on white becomes a deep tint on black instead of a glare.
//
// Every neutral is a semantic system colour. That is what makes dark mode fall
// out for free on screens that still reference these names.

extension Color {
    static let shrunkRed       = Color(hex: "E24B4A")
    static let shrunkRedLight  = Color.dynamic(light: "FCEBEB", dark: "3B1E1E")
    static let shrunkRedDark   = Color.dynamic(light: "9E2725", dark: "FF9E9C")
    static let shrunkRedDeep   = Color.dynamic(light: "B0302F", dark: "F0706E")

    static let verdictGood     = Color.dynamic(light: "1D9E75", dark: "34C99A")
    static let verdictGoodDeep = Color.dynamic(light: "157852", dark: "56DCAF")
    static let verdictGoodTint = Color.dynamic(light: "E8F5EE", dark: "12352A")
    static let verdictWarn     = Color.dynamic(light: "EF9F27", dark: "FFB43F")
    static let verdictWarnDeep = Color.dynamic(light: "B2700B", dark: "FFC97A")
    static let verdictWarnTint = Color.dynamic(light: "FDF1DE", dark: "3A2B10")
    static let verdictBad      = Color(hex: "E24B4A")

    // Neutrals — semantic system colours, so contrast is Apple's problem.
    static let ink             = Color(.label)
    static let inkSubtle       = Color(.secondaryLabel)
    static let smoke           = Color(.secondaryLabel)
    static let smokeSoft       = Color(.tertiaryLabel)
    static let mist            = Color(.tertiarySystemFill)
    static let paper           = Color(.systemGroupedBackground)
    static let surface         = Color(.secondarySystemGroupedBackground)
    static let border          = Color(.separator)
    static let borderSoft      = Color(.separator).opacity(0.6)
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

    /// The native card: an inset-grouped list cell's surface and geometry, with
    /// no hand-drawn border and no shadow. This is what `Section`/`GroupBox`
    /// look like, and it is what every restyled screen uses for a card that
    /// isn't inside a `List`.
    func groupedCard(padding: CGFloat = 16, cornerRadius: CGFloat = 12) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
