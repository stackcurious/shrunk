import Foundation

extension Double {
    /// "$1.89" — 2 decimals, locale-aware currency. Returns "—" for nil-equivalent.
    func formattedPrice(currency: String = "USD") -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        return f.string(from: NSNumber(value: self)) ?? "—"
    }

    /// "5.9¢" or "$1.23" — picks cents when below $1 to make tiny per-oz prices readable.
    func formattedCostPerUnit(currency: String = "USD") -> String {
        if currency == "USD", self < 1.0 {
            return String(format: "%.1f¢", self * 100)
        }
        return formattedPrice(currency: currency)
    }

    /// "28 oz" or "1.5 L" — drops the trailing zero on whole numbers.
    func formattedQuantity(unit: String) -> String {
        let unitLabel = Self.displayUnit(for: unit)
        if self == self.rounded() {
            return "\(Int(self)) \(unitLabel)"
        }
        return String(format: "%.1f %@", self, unitLabel)
    }

    /// "+12.5%" or "−12.5%" with proper minus glyph.
    func formattedPercentChange(decimals: Int = 1) -> String {
        let absVal = abs(self)
        let formatted = String(format: "%.\(decimals)f%%", absVal)
        if self > 0  { return "+" + formatted }
        if self < 0  { return "\u{2212}" + formatted }   // U+2212 minus sign — typographically correct
        return formatted
    }

    /// "12.5%" — magnitude only, no sign.
    func formattedPercent(decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f%%", abs(self))
    }

    private static func displayUnit(for raw: String) -> String {
        switch raw.lowercased() {
        case "fl oz":  return "fl oz"
        case "oz":     return "oz"
        case "g":      return "g"
        case "kg":     return "kg"
        case "ml":     return "ml"
        case "l":      return "L"
        case "count", "ct", "pk": return "ct"
        default:       return raw
        }
    }
}
