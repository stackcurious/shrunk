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
}

struct SizeRecord: Codable, Hashable {
    let date: Date
    let quantity: Double
    let unit: String            // "oz", "fl oz", "g", "kg", "ml", "l", "count"
    let source: String          // "openfoodfacts", "openfoodfacts_import", "user_report"
}
