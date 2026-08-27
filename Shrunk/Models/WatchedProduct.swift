import Foundation
import SwiftData

@Model
final class WatchedProduct {
    @Attribute(.unique) var barcode: String
    var productName: String
    var brand: String
    var lastKnownSize: Double
    var lastKnownUnit: String
    /// The observed price at the user's store the last time we checked
    /// (spec §3.5 — the savings dashboard's per-product input).
    var lastKnownPrice: Double?
    /// Percentage points from the last confirmed size observation (negative
    /// = shrink), matching `ShrinkRecord.shrinkPercent`. Defaulted on the
    /// declaration, not just the init parameter — SwiftData's lightweight
    /// migration reconstructs existing rows without calling `init`.
    var lastShrinkPercent: Double = 0
    var addedAt: Date
    var lastChecked: Date
    var alertEnabled: Bool

    init(
        barcode: String,
        productName: String,
        brand: String,
        lastKnownSize: Double,
        lastKnownUnit: String,
        lastKnownPrice: Double? = nil,
        lastShrinkPercent: Double = 0,
        addedAt: Date = Date(),
        lastChecked: Date = Date(),
        alertEnabled: Bool = true
    ) {
        self.barcode = barcode
        self.productName = productName
        self.brand = brand
        self.lastKnownSize = lastKnownSize
        self.lastKnownUnit = lastKnownUnit
        self.lastKnownPrice = lastKnownPrice
        self.lastShrinkPercent = lastShrinkPercent
        self.addedAt = addedAt
        self.lastChecked = lastChecked
        self.alertEnabled = alertEnabled
    }
}

extension WatchedProduct {
    /// `lastKnownPrice` is carried only when `record.priceIsFromStoreSnapshot`
    /// — the same guard `ShrinkAlert.newShrink(from product:record:)` applies
    /// (R38) — so a curated Browse card's editorial `trending.json` price
    /// (never Kroger-observed) can't feed the "observed only" savings
    /// dashboard.
    static func from(product: ShrunkProduct, record: ShrinkRecord) -> WatchedProduct {
        WatchedProduct(
            barcode: product.id,
            productName: product.name,
            brand: product.brand,
            lastKnownSize: record.currentSize?.quantity ?? 0,
            lastKnownUnit: record.currentSize?.unit ?? "count",
            lastKnownPrice: record.priceIsFromStoreSnapshot ? record.priceNow : nil,
            lastShrinkPercent: record.shrinkPercent
        )
    }
}
