import Foundation

/// Compares historical sizes of a product to determine whether the manufacturer
/// has reduced the package quantity ("shrinkflation") and surfaces the
/// real cost-per-unit shift the customer is now paying.
///
/// Pure logic, no I/O — fed `ShrunkProduct` data assembled by services.
struct ShrinkDetector {

    func analyze(product: ShrunkProduct) -> ShrinkRecord {
        let sorted = product.sizeHistory.sorted { $0.date < $1.date }

        guard sorted.count >= 2 else {
            return ShrinkRecord(
                product: product,
                previousSize: sorted.last,
                currentSize: sorted.last,
                shrinkPercent: 0,
                priceThen: nil,
                priceNow: product.currentPrice,
                costPerUnitThen: nil,
                costPerUnitNow: nil,
                verdict: .insufficientData
            )
        }

        let normalized = sorted.map(Self.normalize)
        let current  = normalized.last!
        let previous = normalized.dropLast().last!

        // Guard against zero-quantity records that would explode the percentage math.
        guard previous.quantity > 0 else {
            return ShrinkRecord(
                product: product,
                previousSize: sorted[sorted.count - 2],
                currentSize: sorted.last!,
                shrinkPercent: 0,
                priceThen: nil,
                priceNow: product.currentPrice,
                costPerUnitThen: nil,
                costPerUnitNow: product.currentPrice.map { $0 / max(current.quantity, 0.0001) },
                verdict: .insufficientData
            )
        }

        let percentChange = ((current.quantity - previous.quantity) / previous.quantity) * 100

        let costPerUnitNow: Double? = product.currentPrice.map { $0 / current.quantity }
        // Historical pricing is rarely available from OFF — left nil at MVP.
        let costPerUnitThen: Double? = nil

        let verdict: ShrinkRecord.ShrinkVerdict = {
            switch percentChange {
            case ..<(-10):    return .significantShrink
            case -10 ..< -5:  return .moderateShrink
            case -5  ..< -1:  return .minorShrink
            case -1  ..< 1:   return .unchanged
            default:          return .grew
            }
        }()

        return ShrinkRecord(
            product: product,
            previousSize: sorted[sorted.count - 2],
            currentSize: sorted.last!,
            shrinkPercent: percentChange,
            priceThen: nil,
            priceNow: product.currentPrice,
            costPerUnitThen: costPerUnitThen,
            costPerUnitNow: costPerUnitNow,
            verdict: verdict
        )
    }

    /// Convert any unit to fluid-ounce-equivalent so percentage comparison is unit-stable.
    /// "count" items pass through unchanged (comparing 12-pack vs 10-pack is already meaningful).
    static func normalize(_ record: SizeRecord) -> SizeRecord {
        let q = record.quantity
        let normalizedQuantity: Double
        switch record.unit.lowercased() {
        case "g":           normalizedQuantity = q * 0.035274
        case "kg":          normalizedQuantity = q * 35.274
        case "ml":          normalizedQuantity = q * 0.033814
        case "l":           normalizedQuantity = q * 33.814
        case "oz", "fl oz": normalizedQuantity = q
        default:            normalizedQuantity = q
        }
        return SizeRecord(
            date: record.date,
            quantity: normalizedQuantity,
            unit: "oz",
            source: record.source
        )
    }
}
