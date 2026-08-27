import Foundation

/// One product's annual cost of shrinking, computed from what we actually
/// observed: the measured size change and the current price at the user's
/// store (spec §3.5).
struct SavingsEntry: Identifiable, Equatable {
    let id: String            // barcode
    let productName: String
    let brand: String
    /// Fraction, not percentage points: a 12.5% shrink is 0.125.
    let shrinkPercentAbs: Double
    let currentPrice: Double
    let annual: Double
    let detectedAt: Date
}

/// The savings dashboard's model.
///
///     annual = |shrink%| × current price × purchases per year
///
/// Every input is observed. Products without a shrink verdict or without a
/// price contribute nothing — no category averages, no assumed basket, no
/// invented unit price.
struct SavingsLedger: Equatable {
    let entries: [SavingsEntry]   // largest annual cost first
    let totalAnnual: Double

    static let empty = SavingsLedger(entries: [], totalAnnual: 0)

    /// Below this the change is inside `ShrinkDetector`'s ±1% unchanged band.
    private static let shrinkThresholdPercent: Double = -1

    static func purchasesPerYear(for frequency: ShopFrequency) -> Double {
        switch frequency {
        case .weekly:   return 52
        case .biweekly: return 26
        case .monthly:  return 12
        }
    }

    static func build(
        alerts: [ShrinkAlert],
        watchlist: [WatchedProduct],
        shopFrequency: ShopFrequency
    ) -> SavingsLedger {
        let purchases = purchasesPerYear(for: shopFrequency)

        // Alerts are the fresher observation, so they win a barcode collision.
        var byBarcode: [String: SavingsEntry] = [:]

        for watched in watchlist {
            guard let entry = makeEntry(
                barcode: watched.barcode,
                productName: watched.productName,
                brand: watched.brand,
                shrinkPercent: watched.lastShrinkPercent,
                price: watched.lastKnownPrice,
                detectedAt: watched.lastChecked,
                purchases: purchases
            ) else { continue }
            byBarcode[watched.barcode] = entry
        }

        // Only kinds that mean "this really did shrink" (spec §3.5) — a push
        // digest or an unconfirmed re-scan hint isn't an observed shrink and
        // must not cost the user a dollar figure it can't back up. Sorted
        // newest-first here (not just assumed from the caller's @Query
        // order) so the first qualifying alert per barcode is always the
        // newest observation — a barcode already claimed by a newer alert is
        // never overwritten by an older one.
        var claimedByAlert: Set<String> = []
        for alert in alerts.sorted(by: { $0.createdAt > $1.createdAt }) where alert.kind.isConfirmedShrink {
            guard !claimedByAlert.contains(alert.barcode) else { continue }
            guard let entry = makeEntry(
                barcode: alert.barcode,
                productName: alert.productName,
                brand: alert.brand,
                shrinkPercent: alert.shrinkPercent,
                price: alert.currentPrice,
                detectedAt: alert.createdAt,
                purchases: purchases
            ) else { continue }
            byBarcode[alert.barcode] = entry
            claimedByAlert.insert(alert.barcode)
        }

        guard !byBarcode.isEmpty else { return .empty }

        let entries = byBarcode.values.sorted {
            $0.annual == $1.annual ? $0.id < $1.id : $0.annual > $1.annual
        }
        return SavingsLedger(
            entries: entries,
            totalAnnual: entries.reduce(0) { $0 + $1.annual }
        )
    }

    private static func makeEntry(
        barcode: String,
        productName: String,
        brand: String,
        shrinkPercent: Double,
        price: Double?,
        detectedAt: Date,
        purchases: Double
    ) -> SavingsEntry? {
        guard shrinkPercent < shrinkThresholdPercent else { return nil }
        guard let price, price > 0 else { return nil }

        let fraction = abs(shrinkPercent) / 100
        return SavingsEntry(
            id: barcode,
            productName: productName,
            brand: brand,
            shrinkPercentAbs: fraction,
            currentPrice: price,
            annual: fraction * price * purchases,
            detectedAt: detectedAt
        )
    }
}

extension SavingsLedger {
    /// "$487" — the dashboard hero.
    var totalDisplay: String { Self.currencyString(totalAnnual) }

    static func currencyString(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 0
        formatter.locale = .current
        return formatter.string(from: NSNumber(value: value)) ?? "$0"
    }
}
