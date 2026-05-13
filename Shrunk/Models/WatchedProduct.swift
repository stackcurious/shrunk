import Foundation
import SwiftData

@Model
final class WatchedProduct {
    @Attribute(.unique) var barcode: String
    var productName: String
    var brand: String
    var lastKnownSize: Double
    var lastKnownUnit: String
    var addedAt: Date
    var lastChecked: Date
    var alertEnabled: Bool

    init(
        barcode: String,
        productName: String,
        brand: String,
        lastKnownSize: Double,
        lastKnownUnit: String,
        addedAt: Date = Date(),
        lastChecked: Date = Date(),
        alertEnabled: Bool = true
    ) {
        self.barcode = barcode
        self.productName = productName
        self.brand = brand
        self.lastKnownSize = lastKnownSize
        self.lastKnownUnit = lastKnownUnit
        self.addedAt = addedAt
        self.lastChecked = lastChecked
        self.alertEnabled = alertEnabled
    }
}

extension WatchedProduct {
    static func from(product: ShrunkProduct, currentSize: SizeRecord) -> WatchedProduct {
        WatchedProduct(
            barcode: product.id,
            productName: product.name,
            brand: product.brand,
            lastKnownSize: currentSize.quantity,
            lastKnownUnit: currentSize.unit
        )
    }
}
