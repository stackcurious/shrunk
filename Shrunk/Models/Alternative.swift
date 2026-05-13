import Foundation

struct Alternative: Identifiable, Hashable {
    let id: String              // barcode of the alternative
    let name: String
    let brand: String
    let size: String            // human-readable: "32 oz"
    let costPerUnit: Double     // per oz, normalized
    let savingsPercent: Double  // vs the scanned product (positive = cheaper)
    let hasShrunkBefore: Bool
    let imageURL: URL?
    let verdict: String         // "26% cheaper per oz. Hasn't shrunk since 2019."
}
