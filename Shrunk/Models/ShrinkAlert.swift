import Foundation
import SwiftData

@Model
final class ShrinkAlert {
    @Attribute(.unique) var id: UUID
    var barcode: String
    var productName: String
    var brand: String
    var kindRaw: String
    var previousQuantity: Double?
    var previousUnit: String?
    var currentQuantity: Double?
    var currentUnit: String?
    var shrinkPercent: Double
    var costDeltaPerUnit: Double?
    var createdAt: Date
    var isRead: Bool

    init(
        id: UUID = UUID(),
        barcode: String,
        productName: String,
        brand: String,
        kind: Kind,
        previousQuantity: Double? = nil,
        previousUnit: String? = nil,
        currentQuantity: Double? = nil,
        currentUnit: String? = nil,
        shrinkPercent: Double = 0,
        costDeltaPerUnit: Double? = nil,
        createdAt: Date = Date(),
        isRead: Bool = false
    ) {
        self.id = id
        self.barcode = barcode
        self.productName = productName
        self.brand = brand
        self.kindRaw = kind.rawValue
        self.previousQuantity = previousQuantity
        self.previousUnit = previousUnit
        self.currentQuantity = currentQuantity
        self.currentUnit = currentUnit
        self.shrinkPercent = shrinkPercent
        self.costDeltaPerUnit = costDeltaPerUnit
        self.createdAt = createdAt
        self.isRead = isRead
    }

    enum Kind: String, Codable, CaseIterable {
        case newShrink     // confirmed shrinkage just detected
        case unconfirmed   // possible change, needs user re-scan
        case stable        // no change since last check
    }

    var kind: Kind { Kind(rawValue: kindRaw) ?? .stable }
}

extension ShrinkAlert {
    static func newShrink(from watched: WatchedProduct, record: ShrinkRecord) -> ShrinkAlert {
        ShrinkAlert(
            barcode: watched.barcode,
            productName: watched.productName,
            brand: watched.brand,
            kind: .newShrink,
            previousQuantity: record.previousSize?.quantity,
            previousUnit: record.previousSize?.unit,
            currentQuantity: record.currentSize?.quantity,
            currentUnit: record.currentSize?.unit,
            shrinkPercent: record.shrinkPercent,
            costDeltaPerUnit: nil
        )
    }
}
