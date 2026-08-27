import Foundation

struct ShrinkRecord: Hashable {
    let product: ShrunkProduct
    let previousSize: SizeRecord?
    let currentSize: SizeRecord?
    let shrinkPercent: Double           // negative = shrink, positive = growth, 0 = unchanged
    let priceThen: Double?
    let priceNow: Double?
    let costPerUnitThen: Double?        // price / quantity, both in normalized units
    let costPerUnitNow: Double?
    /// True only when `priceNow` came from a `product.priceHistory` entry
    /// (`price_snapshots` — Kroger-derived). False when it fell back to
    /// `product.currentPrice` with no snapshot history (e.g. curated Browse
    /// cards from `TrendingEntry.toProduct()`), which is not Kroger data and
    /// must never carry Kroger attribution (Phase 3 review I6 regression).
    let priceIsFromStoreSnapshot: Bool
    let verdict: ShrinkVerdict

    enum ShrinkVerdict: Hashable {
        case significantShrink          // > 10% reduction
        case moderateShrink             // 5–10%
        case minorShrink                // 1–5%
        case unchanged
        case grew
        case insufficientData
    }
}

extension ShrinkRecord.ShrinkVerdict {
    var isShrink: Bool {
        switch self {
        case .significantShrink, .moderateShrink, .minorShrink: return true
        default: return false
        }
    }
}
