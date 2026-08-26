import Foundation

struct Alternative: Identifiable, Hashable {
    enum Source: String, Hashable {
        case store      // live from the user's Kroger
        case curated    // verified case from the trending feed
    }

    let id: String              // 13-digit GTIN
    let name: String
    let brand: String
    let size: String            // human-readable: "32 fl oz"
    let costPerUnit: Double?    // $/oz-equivalent — nil for curated rows
    let savingsPercent: Double? // vs the scanned product; nil when we can't compare
    let imageURL: URL?
    let verdict: String
    let source: Source
    let price: Double?          // shelf price at the store
    let stockLabel: String?     // "In stock" / "Low stock"
}

/// What the alternatives sheet renders: the rows the caller may see, how many
/// were withheld behind Pro, and whether these are store prices or curated cases.
struct AlternativesResult: Hashable {
    let alternatives: [Alternative]
    let hiddenCount: Int
    let isCurated: Bool

    static let empty = AlternativesResult(alternatives: [], hiddenCount: 0, isCurated: false)
}
