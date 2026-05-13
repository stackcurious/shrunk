import Foundation

/// Catch-level savings record derived from a ShrinkAlert + the user's profile.
/// Computed on-demand so we don't have to migrate the SwiftData store when the
/// formula changes.
struct SavingsCatch: Identifiable, Equatable {
    let id: UUID
    let productName: String
    let brand: String
    let shrinkPercent: Double
    let detectedAt: Date
    let estimatedAnnualSavings: Double
}

/// Aggregates a list of alerts into a savings view-model.
/// All formulas are documented inline so we can defend the numbers if asked.
struct SavingsLedger: Equatable {
    let totalProtected: Double         // since first catch
    let thisMonth: Double               // catches in the current calendar month
    let ongoingAnnual: Double           // sum of per-catch annualized exposure
    let catches: [SavingsCatch]         // newest first
    let dailyTotals: [DailyTotal]       // for the chart, oldest first

    struct DailyTotal: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let cumulative: Double
    }

    static let empty = SavingsLedger(
        totalProtected: 0,
        thisMonth: 0,
        ongoingAnnual: 0,
        catches: [],
        dailyTotals: []
    )

    /// Builds a ledger from the SwiftData alert feed + the user's saved profile.
    static func build(alerts: [ShrinkAlert], profile: OnboardingProfile) -> SavingsLedger {
        let confirmed = alerts.filter { $0.kind == .newShrink }
        guard !confirmed.isEmpty else { return .empty }

        let frequency = purchasesPerYear(for: profile.shopFrequency)

        let mapped: [SavingsCatch] = confirmed.map { alert in
            let annual = estimateAnnualSavings(
                shrinkPercent: alert.shrinkPercent,
                purchasesPerYear: frequency
            )
            return SavingsCatch(
                id: alert.id,
                productName: alert.productName,
                brand: alert.brand,
                shrinkPercent: alert.shrinkPercent,
                detectedAt: alert.createdAt,
                estimatedAnnualSavings: annual
            )
        }

        let sortedNewest = mapped.sorted { $0.detectedAt > $1.detectedAt }
        let total = mapped.reduce(0) { $0 + $1.estimatedAnnualSavings }

        // "This month" uses the calendar month, not a 30-day rolling window —
        // matches how users read "monthly" stats.
        let cal = Calendar.current
        let thisMonth = mapped
            .filter { cal.isDate($0.detectedAt, equalTo: Date(), toGranularity: .month) }
            .reduce(0) { $0 + $1.estimatedAnnualSavings / 12 }

        return SavingsLedger(
            totalProtected: total,
            thisMonth: thisMonth,
            ongoingAnnual: total,
            catches: sortedNewest,
            dailyTotals: buildDailyTotals(from: mapped.sorted { $0.detectedAt < $1.detectedAt })
        )
    }

    // MARK: - Per-catch math
    //
    // Formula (annualized):
    //     loss_per_purchase = typical_unit_price × |shrinkPercent|
    //     annual_savings    = loss_per_purchase × purchases_per_year
    //
    // We use a fixed `typicalUnitPrice` because OFF rarely publishes pricing.
    // $5 is the broad grocery-item average (snack bag, drink, cleaning product,
    // toothpaste) — defensible as a back-of-envelope number; if we ever start
    // tracking real prices in WatchedProduct we'd replace this.

    private static let typicalUnitPrice: Double = 5.0

    private static func estimateAnnualSavings(shrinkPercent: Double, purchasesPerYear: Double) -> Double {
        let perPurchase = typicalUnitPrice * abs(shrinkPercent)
        return perPurchase * purchasesPerYear
    }

    private static func purchasesPerYear(for freq: ShopFrequency?) -> Double {
        switch freq {
        case .weekly:   return 52
        case .biweekly: return 26
        case .monthly:  return 12
        case .none:     return 26
        }
    }

    // MARK: - Chart series

    /// Cumulative running total per day for the last 90 days. Used for the
    /// area chart in the dashboard. If we have fewer than 2 catches, we
    /// return an empty series — the chart caller hides the chart in that case.
    private static func buildDailyTotals(from sortedOldestFirst: [SavingsCatch]) -> [DailyTotal] {
        guard sortedOldestFirst.count >= 2 else { return [] }

        let cal = Calendar.current
        var runningTotal: Double = 0
        var dailyTotals: [DailyTotal] = []
        var lastDay: Date?

        for c in sortedOldestFirst {
            let day = cal.startOfDay(for: c.detectedAt)
            runningTotal += c.estimatedAnnualSavings
            if let last = lastDay, last == day, var existing = dailyTotals.last {
                existing = DailyTotal(date: day, cumulative: runningTotal)
                dailyTotals[dailyTotals.count - 1] = existing
            } else {
                dailyTotals.append(DailyTotal(date: day, cumulative: runningTotal))
            }
            lastDay = day
        }

        // Anchor a leading zero at the day before the first catch so the line
        // starts from the bottom rather than at the first catch's value.
        if let first = dailyTotals.first,
           let leadingDate = cal.date(byAdding: .day, value: -1, to: first.date) {
            dailyTotals.insert(DailyTotal(date: leadingDate, cumulative: 0), at: 0)
        }

        return dailyTotals
    }
}

extension SavingsLedger {
    /// "$487" — used for the hero number.
    var totalDisplay: String { Self.currencyString(totalProtected) }
    var thisMonthDisplay: String { Self.currencyString(thisMonth) }
    var ongoingAnnualDisplay: String { Self.currencyString(ongoingAnnual) }

    static func currencyString(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 0
        formatter.locale = .current
        return formatter.string(from: NSNumber(value: value)) ?? "$0"
    }
}
