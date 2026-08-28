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
// This is the whole theme now. Two rules, both from the native-UI spec (§3):
//   1. Brand red `#E24B4A` is the app tint and does not move between schemes.
//   2. Verdict colour *meaning* is fixed (red = shrink, amber = minor, green =
//      unchanged/grew) but the actual values adapt, so a wash that reads as a
//      pale tint on white becomes a deep tint on black instead of a glare.
//
// Everything else — neutrals, type, spacing, radii, elevation — comes from the
// system: `Color(.label)` / `.secondary`, the built-in text styles, and the
// grouped-list surfaces below. The `paper`/`ink`/`mist`/`smoke` palette, the
// `Font.shrunk*` faces and the `ShrunkTheme` spacing/radius/elevation tokens
// were deleted with the last screen that referenced them (spec §3).

extension Color {
    static let shrunkRed       = Color(hex: "E24B4A")
    static let shrunkRedLight  = Color.dynamic(light: "FCEBEB", dark: "3B1E1E")
    static let shrunkRedDark   = Color.dynamic(light: "9E2725", dark: "FF9E9C")

    static let verdictGood     = Color.dynamic(light: "1D9E75", dark: "34C99A")
    static let verdictGoodDeep = Color.dynamic(light: "157852", dark: "56DCAF")
    static let verdictGoodTint = Color.dynamic(light: "E8F5EE", dark: "12352A")
    /// The one green that does *not* adapt. Anything that paints white text on
    /// a green capsule has to pin the fill, or the pair adapts on one side only
    /// and the badge falls to 2.1:1 in dark mode. White on this is 5.5:1 in
    /// both schemes.
    static let verdictGoodSolid = Color(hex: "157852")
    // `EF9F27` was 2.17:1 on a white card — under even the 3:1 non-text floor,
    // and it is the *sole* signal for a minor/moderate shrink (meter numeral
    // and ring, alert glyph, history bar). Both amber values are now dark
    // enough to carry meaning on white: `B2700B` is 4.0:1 (non-text and large
    // text pass), `8A5600` is 6.2:1 on white and 5.5:1 on `verdictWarnTint`.
    static let verdictWarn     = Color.dynamic(light: "B2700B", dark: "FFB43F")
    static let verdictWarnDeep = Color.dynamic(light: "8A5600", dark: "FFC97A")
    static let verdictWarnTint = Color.dynamic(light: "FDF1DE", dark: "3A2B10")
    static let verdictBad      = Color(hex: "E24B4A")
}

// MARK: - View modifiers

extension View {
    /// The native card: an inset-grouped list cell's surface and geometry, with
    /// no hand-drawn border and no shadow. This is what `Section`/`GroupBox`
    /// look like, and it is what every screen uses for a card that isn't inside
    /// a `List`.
    func groupedCard(padding: CGFloat = 16, cornerRadius: CGFloat = 12) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
