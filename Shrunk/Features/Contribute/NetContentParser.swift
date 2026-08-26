import Foundation

/// Base unit per kind: grams, millilitres, or a plain count (spec §5.1).
enum UnitKind: String, CaseIterable, Codable {
    case mass, volume, count

    /// Label used in the confirm sheet and the admin review page.
    var displayLabel: String {
        switch self {
        case .mass:   return "g"
        case .volume: return "mL"
        case .count:  return "count"
        }
    }
}

struct ParsedQuantity: Equatable {
    let quantity: Double        // grams | millilitres | count
    let unitKind: UnitKind
    let raw: String
}

struct NetContentMatch: Equatable {
    let line: String
    let lineIndex: Int
    let parsed: ParsedQuantity
}

/// Swift port of `backend/src/normalize.ts` / `scripts/fdc/normalize.py`.
/// All three must pass `fixtures/package_weights.json` — change one, change all three.
enum NetContentParser {

    // MARK: - Units

    private static let units: [String: (UnitKind, Double)] = [
        // mass -> grams
        "g": (.mass, 1), "gr": (.mass, 1), "gram": (.mass, 1), "grams": (.mass, 1), "grm": (.mass, 1),
        "kg": (.mass, 1000), "kgm": (.mass, 1000), "kilogram": (.mass, 1000), "kilograms": (.mass, 1000),
        "oz": (.mass, 28.3495), "onz": (.mass, 28.3495), "ounce": (.mass, 28.3495), "ounces": (.mass, 28.3495),
        "lb": (.mass, 453.592), "lbs": (.mass, 453.592), "lbr": (.mass, 453.592),
        "pound": (.mass, 453.592), "pounds": (.mass, 453.592),
        // volume -> millilitres
        "ml": (.volume, 1), "mlt": (.volume, 1), "milliliter": (.volume, 1),
        "milliliters": (.volume, 1), "millilitre": (.volume, 1),
        "l": (.volume, 1000), "ltr": (.volume, 1000), "liter": (.volume, 1000),
        "liters": (.volume, 1000), "litre": (.volume, 1000), "litres": (.volume, 1000),
        "floz": (.volume, 29.5735), "oza": (.volume, 29.5735),
        "pt": (.volume, 473.176), "ptl": (.volume, 473.176), "pint": (.volume, 473.176), "pints": (.volume, 473.176),
        "qt": (.volume, 946.353), "qtl": (.volume, 946.353), "quart": (.volume, 946.353), "quarts": (.volume, 946.353),
        "gal": (.volume, 3785.41), "gll": (.volume, 3785.41), "gallon": (.volume, 3785.41), "gallons": (.volume, 3785.41),
        // count
        "ct": (.count, 1), "count": (.count, 1), "pk": (.count, 1), "pack": (.count, 1),
        "ea": (.count, 1), "each": (.count, 1), "h87": (.count, 1),
        "pc": (.count, 1), "pcs": (.count, 1), "piece": (.count, 1), "pieces": (.count, 1)
    ]

    /// Longest token first so "milliliters" wins over "ml"; sorted for determinism.
    private static let unitAlternation: String = units.keys
        .sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
        .map { NSRegularExpression.escapedPattern(for: $0) }
        .joined(separator: "|")

    private static let numberPattern = #"(\d+(?:[.,]\d+)?)"#

    /// "12 - 12 FL OZ", "6 x 330 ml" — multiplier, then quantity and unit.
    private static let multipack = try! NSRegularExpression(
        pattern: "\(numberPattern)\\s*(?:[-–x×*]|pk\\s+of|pack\\s+of)\\s*\(numberPattern)\\s*(fl\\s?oz|\(unitAlternation))\\b"
    )

    private static let quantityUnit = try! NSRegularExpression(
        pattern: "\(numberPattern)\\s*(fl\\s?oz|\(unitAlternation))\\b"
    )

    /// "12 oz/340 g" and "NET WT 12 OZ (340g)" both split into comparable segments.
    private static let segmentSplit = try! NSRegularExpression(pattern: #"\s*/\s*|\s*\(|\)\s*"#)

    /// Spec §6.3 — the lines a label uses to announce net content.
    private static let netContentMarker = try! NSRegularExpression(
        pattern: #"NET\s*(WT|WEIGHT|CONTENTS?)|e\s*\d"#,
        options: [.caseInsensitive]
    )

    private static let tolerance = 0.02

    // MARK: - Public API

    static func parse(_ raw: String) -> ParsedQuantity? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let parsed = segments(of: text).compactMap(parseSegment)
        guard !parsed.isEmpty else { return nil }

        // Prefer mass/volume over count when both appear ("12 ct / 340 g").
        let nonCount = parsed.filter { $0.kind != .count }
        let chosen = nonCount.isEmpty ? parsed : nonCount
        let head = chosen[0]

        // Same-kind segments must agree within 2%, or the string is malformed.
        for other in chosen.dropFirst() where other.kind == head.kind {
            if abs(other.value - head.value) / head.value > tolerance { return nil }
        }

        return ParsedQuantity(
            quantity: (head.value * 1000).rounded() / 1000,
            unitKind: head.kind,
            raw: raw
        )
    }

    static func isNetContentLine(_ line: String) -> Bool {
        netContentMarker.firstMatch(in: line, range: fullRange(of: line)) != nil
    }

    /// Picks the OCR line to submit.
    /// Tier 1 is spec §6.3's rule — lines that announce net content.
    /// Tier 2 catches labels that print the size with no prefix ("12 – 12 FL OZ
    /// CANS"); it accepts mass/volume only, so a bare "12 CT" (as likely to be
    /// servings as packages) falls through to the manual entry sheet (spec §8).
    static func firstNetContent(in lines: [String]) -> NetContentMatch? {
        for (index, line) in lines.enumerated() where isNetContentLine(line) {
            if let parsed = parse(line) {
                return NetContentMatch(line: line, lineIndex: index, parsed: parsed)
            }
        }
        for (index, line) in lines.enumerated() {
            if let parsed = parse(line), parsed.unitKind != .count {
                return NetContentMatch(line: line, lineIndex: index, parsed: parsed)
            }
        }
        return nil
    }

    // MARK: - Internals

    private struct Segment {
        let value: Double
        let kind: UnitKind
    }

    private static func fullRange(of text: String) -> NSRange {
        NSRange(location: 0, length: (text as NSString).length)
    }

    private static func segments(of text: String) -> [String] {
        let ns = text as NSString
        var result: [String] = []
        var cursor = 0
        for match in segmentSplit.matches(in: text, range: fullRange(of: text)) {
            result.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            cursor = match.range.location + match.range.length
        }
        result.append(ns.substring(from: cursor))
        return result
    }

    private static func parseSegment(_ segment: String) -> Segment? {
        let text = segment.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let ns = text as NSString
        let range = fullRange(of: text)

        if let match = multipack.firstMatch(in: text, range: range),
           let unit = unit(ns.substring(with: match.range(at: 3))) {
            let value = number(ns.substring(with: match.range(at: 1)))
                * number(ns.substring(with: match.range(at: 2)))
                * unit.1
            return value > 0 ? Segment(value: value, kind: unit.0) : nil
        }

        let matches = quantityUnit.matches(in: text, range: range)
        guard let head = matches.first,
              let headUnit = unit(ns.substring(with: head.range(at: 2))) else { return nil }

        var total = number(ns.substring(with: head.range(at: 1))) * headUnit.1
        // Compound imperial ("1 lb 4 oz"): same-kind trailing matches add up.
        for extra in matches.dropFirst() {
            guard let extraUnit = unit(ns.substring(with: extra.range(at: 2))),
                  extraUnit.0 == headUnit.0 else { break }
            total += number(ns.substring(with: extra.range(at: 1))) * extraUnit.1
        }
        return total > 0 ? Segment(value: total, kind: headUnit.0) : nil
    }

    private static func number(_ token: String) -> Double {
        Double(token.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private static func unit(_ token: String) -> (UnitKind, Double)? {
        units[token.lowercased().replacingOccurrences(of: " ", with: "")]
    }
}
