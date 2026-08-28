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

    /// What the store actually told us about availability. `unknown` is its own
    /// state: a missing or unrecognised `stockLevel` is an absence of an answer,
    /// not a "yes".
    var stockState: StockState {
        switch (stockLevel ?? "").uppercased() {
        case "HIGH":                     return .inStock
        case "LOW":                      return .low
        case "TEMPORARILY_OUT_OF_STOCK": return .outOfStock
        default:                         return .unknown
        }
    }

    /// Only true when the store said the product is on the shelf. Surfaces that
    /// paint a green "it's there" capsule must use this, never the negation of
    /// `isOutOfStock`.
    var inStock: Bool { stockState == .inStock || stockState == .low }

    /// Only true when the store said it is *out*. This is the filter
    /// `AlternativesEngine` wants — dropping every row with no stock field
    /// would empty the list on a store that simply doesn't report it.
    var isOutOfStock: Bool { stockState == .outOfStock }

    var stockLabel: String {
        switch stockState {
        case .inStock:    return "In stock"
        case .low:        return "Low stock"
        case .outOfStock: return "Out of stock"
        case .unknown:    return "Stock unknown"
        }
    }
}

/// Availability as reported by the store, with "we weren't told" kept distinct
/// from "yes" and "no".
enum StockState: Hashable {
    case inStock
    case low
    case outOfStock
    case unknown
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
    /// Which store API produced this row, carried through into any
    /// `SizeRecord` adopted from it (spec rule 5) so the observation is
    /// attributed to whoever actually reported it. `/v1/kroger/product` is the
    /// only live provider today; a second one sets this rather than silently
    /// inheriting Kroger's name — the same failure `priceIsFromStoreSnapshot`
    /// guards against on the price side.
    var source: String = "kroger"
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
