import Foundation

/// Compares historical sizes of a product to determine whether the manufacturer
/// has reduced the package quantity ("shrinkflation") and surfaces the
/// real cost-per-unit shift the customer is now paying.
///
/// Pure logic, no I/O — fed `ShrunkProduct` data assembled by services.
struct ShrinkDetector {

    func analyze(product: ShrunkProduct) -> ShrinkRecord {
        let sorted = product.sizeHistory.sorted { $0.date < $1.date }

        // Only compare records of the same kind as the most recent one —
        // grams vs fluid ounces must never produce a verdict.
        let sameKind: [SizeRecord] = {
            guard let latestKind = sorted.last?.unitKind else { return [] }
            return sorted.filter { $0.unitKind == latestKind }
        }()

        // The two most recent store snapshots, oldest first.
        let prices = product.priceHistory.sorted { $0.date < $1.date }
        let priceNow = prices.last?.price ?? product.currentPrice
        let priceThen = prices.count >= 2 ? prices[prices.count - 2].price : nil

        guard sameKind.count >= 2 else {
            return ShrinkRecord(
                product: product,
                previousSize: sorted.last,
                currentSize: sorted.last,
                shrinkPercent: 0,
                priceThen: nil,
                priceNow: priceNow,
                costPerUnitThen: nil,
                costPerUnitNow: nil,
                verdict: .insufficientData
            )
        }

        let normalized = sameKind.map(Self.normalize)
        let current  = normalized.last!
        let previous = normalized.dropLast().last!

        // Guard against zero-quantity records that would explode the percentage math.
        guard previous.quantity > 0 else {
            return ShrinkRecord(
                product: product,
                previousSize: sameKind[sameKind.count - 2],
                currentSize: sameKind.last!,
                shrinkPercent: 0,
                priceThen: priceThen,
                priceNow: priceNow,
                costPerUnitThen: nil,
                costPerUnitNow: priceNow.map { $0 / max(current.quantity, 0.0001) },
                verdict: .insufficientData
            )
        }

        let percentChange = ((current.quantity - previous.quantity) / previous.quantity) * 100

        // "Now" is today's price over today's size; "then" is the older snapshot
        // over the older size — the cost this shopper used to pay.
        let costPerUnitNow: Double? = priceNow.map { $0 / current.quantity }
        let costPerUnitThen: Double? = priceThen.map { $0 / previous.quantity }

        let verdict: ShrinkRecord.ShrinkVerdict = {
            switch percentChange {
            case ..<(-10):    return .significantShrink
            case -10 ..< -5:  return .moderateShrink
            case -5  ..< -1:  return .minorShrink
            case -1 ..< 1:    return .unchanged
            default:          return .grew
            }
        }()

        return ShrinkRecord(
            product: product,
            previousSize: sameKind[sameKind.count - 2],
            currentSize: sameKind.last!,
            shrinkPercent: percentChange,
            priceThen: priceThen,
            priceNow: priceNow,
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
