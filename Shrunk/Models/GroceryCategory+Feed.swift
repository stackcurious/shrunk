import Foundation

extension GroceryCategory {
    /// The category name the backend uses in `products.category`, `/v1/feed`
    /// and the weekly digest. The app's own titles are shorter ("Drinks",
    /// "Personal"); the Worker canonicalises both spellings onto these.
    var feedCategory: String {
        switch self {
        case .snacks:   return "Snacks"
        case .drinks:   return "Beverages"
        case .dairy:    return "Dairy"
        case .cleaning: return "Cleaning"
        case .personal: return "Personal care"
        case .paper:    return "Paper products"
        }
    }
}
