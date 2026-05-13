import Foundation

/// Computes the personalized annual shrinkflation exposure number that
/// powers the onboarding reveal and the paywall payback anchor.
///
/// Math (documented in tasks/shrunk_v2_monetization.md):
///     annualSpend     = monthlySpend × 12
///     perCategory($)  = annualSpend × basketShare × shrinkRate
///     totalAnnual($)  = Σ perCategory($) over selected categories
///     paybackDays     = ceil(365 × 9.99 / totalAnnual)
struct SavingsForecast: Equatable {
    struct Slice: Equatable, Identifiable {
        var id: String { category.rawValue }
        let category: GroceryCategory
        let annualLoss: Double
    }

    let totalAnnual: Double
    let perCategory: [Slice]
    let paybackDays: Int

    static let proPrice: Double = 9.99

    static func compute(profile: OnboardingProfile) -> SavingsForecast {
        let monthly = profile.monthlySpend ?? OnboardingProfile.defaultSpend
        let annualSpend = monthly * 12

        // If user selected no categories (shouldn't happen in normal flow, but defensible),
        // assume all six — gives them a "you're exposed across the board" reveal.
        let selected = profile.categories.isEmpty
            ? Set(GroceryCategory.allCases)
            : profile.categories

        let slices = GroceryCategory.allCases
            .filter { selected.contains($0) }
            .map { cat in
                Slice(
                    category: cat,
                    annualLoss: annualSpend * cat.basketShare * cat.shrinkRate
                )
            }
            .sorted { $0.annualLoss > $1.annualLoss }

        let total = slices.reduce(0) { $0 + $1.annualLoss }

        let paybackDays: Int
        if total > 0 {
            paybackDays = max(1, Int(ceil(365.0 * proPrice / total)))
        } else {
            paybackDays = 365
        }

        return SavingsForecast(
            totalAnnual: total,
            perCategory: slices,
            paybackDays: paybackDays
        )
    }

    /// Whole-dollar string used in the reveal hero: `$284`.
    var totalDisplay: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 0
        formatter.locale = .current
        return formatter.string(from: NSNumber(value: totalAnnual)) ?? "$0"
    }
}
