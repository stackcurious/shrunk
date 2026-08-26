import Foundation

struct ShrunkProduct: Identifiable, Codable, Hashable {
    let id: String              // barcode (UPC / EAN)
    let name: String
    let brand: String
    let category: String
    let imageURL: URL?
    let sizeHistory: [SizeRecord]
    let currentPrice: Double?
    let currency: String
    /// Set in Phase 3 when the live store size disagrees with the latest
    /// non-Kroger observation (spec §4 step 4). Drives the "Confirm with a
    /// label photo" card on ResultView.
    var needsConfirmation: Bool = false
}

struct SizeRecord: Codable, Hashable {
    let date: Date
    let quantity: Double
    let unit: String            // "oz", "fl oz", "g", "kg", "ml", "l", "count"
    let source: String          // "openfoodfacts", "openfoodfacts_import", "user_report"
}

extension SizeRecord {
    /// "mass" | "volume" | "count" | "unknown" — observations of different kinds are never compared.
    var unitKind: String {
        switch unit.lowercased().replacingOccurrences(of: " ", with: "") {
        case "g", "gram", "grams", "kg", "oz", "ounce", "ounces", "lb", "lbs":
            return "mass"
        case "ml", "l", "floz", "liter", "litre":
            return "volume"
        case "count", "ct", "pk", "pack", "each", "ea":
            return "count"
        default:
            return "unknown"
        }
    }
}
