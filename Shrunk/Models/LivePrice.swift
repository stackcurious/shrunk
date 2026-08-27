import Foundation

/// Shared price/stock behaviour for anything priced at a store.
protocol StorePriced {
    var regular: Double? { get }
    var promo: Double? { get }
    var stockLevel: String? { get }
}

extension StorePriced {
    /// Promo when there is one, otherwise the regular shelf price.
    var effectivePrice: Double? {
        if let promo, promo > 0 { return promo }
        if let regular, regular > 0 { return regular }
        return nil
    }

    var isOnPromo: Bool {
        guard let promo, promo > 0, let regular else { return false }
        return regular > promo
    }

    var inStock: Bool { (stockLevel ?? "").uppercased() != "TEMPORARILY_OUT_OF_STOCK" }

    var stockLabel: String {
        switch (stockLevel ?? "").uppercased() {
        case "HIGH":                     return "In stock"
        case "LOW":                      return "Low stock"
        case "TEMPORARILY_OUT_OF_STOCK": return "Out of stock"
        default:                         return "Stock unknown"
        }
    }
}

/// Live price for the scanned product at the user's store. Every surface that
/// shows one must also show `LivePrice.attribution` (Kroger terms, spec §9).
struct LivePrice: Hashable, StorePriced {
    static let attribution = "Prices from Kroger"

    let gtin: String
    let locationId: String
    let brand: String
    let description: String
    let size: String?
    let quantity: Double?       // grams | millilitres | count
    let unitKind: String?       // mass | volume | count
    let regular: Double?
    let promo: Double?
    let perUnitEstimate: Double?
    let stockLevel: String?
}

/// One candidate in the store-backed alternatives list.
struct StoreSearchResult: Hashable, StorePriced {
    let gtin: String?
    let productId: String
    let brand: String
    let description: String
    let category: String
    let imageURL: URL?
    let size: String?
    let quantity: Double?
    let unitKind: String?
    let regular: Double?
    let promo: Double?
    let stockLevel: String?
}
