import SwiftUI

/// Live shelf price at the user's store. Kroger's terms require the
/// attribution wherever their data appears (spec §9).
struct LivePricePanel: View {
    let state: LivePriceState
    let storeName: String

    var body: some View {
        switch state {
        case .hidden:
            EmptyView()
        case .loading:
            card {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking \(storeName.isEmpty ? "your store" : storeName)…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        case .unavailable:
            card {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Store prices unavailable right now")
                        .font(.subheadline.weight(.semibold))
                    Text("The verdict and size history above don't need them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        case .loaded(let live):
            card { loaded(live) }
        }
    }

    @ViewBuilder
    private func loaded(_ live: LivePrice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let price = live.effectivePrice {
                    Text(price.formattedPrice())
                        .font(.title.bold())
                        .monospacedDigit()
                } else {
                    Text("—")
                        .font(.title.bold())
                        .foregroundStyle(.secondary)
                }
                if live.isOnPromo, let regular = live.regular {
                    Text(regular.formattedPrice())
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .strikethrough()
                    Text("Promo")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.shrunkRed, in: Capsule())
                }
                Spacer(minLength: 0)
                Text(live.stockLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(live.inStock ? Color.verdictGoodDeep : Color.shrunkRedDark)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(live.inStock ? Color.verdictGoodTint : Color.shrunkRedLight, in: Capsule())
            }

            HStack(spacing: 16) {
                if let size = live.size, !size.isEmpty {
                    detail(label: "Size", value: size)
                }
                if let perOz = costPerOunce(live) {
                    detail(label: "Cost / oz", value: perOz.formattedCostPerUnit())
                }
            }
        }
    }

    /// Same oz-equivalent space the verdict uses, so the two numbers agree
    /// (shared with `AlternativesEngine.costPerOunce` — Phase 3 review T17).
    private func costPerOunce(_ live: LivePrice) -> Double? {
        ShrinkDetector.costPerOunce(price: live.effectivePrice, quantity: live.quantity, unitKind: live.unitKind)
    }

    private func detail(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(storeName.isEmpty ? "At your store" : storeName)
                    .font(.headline)
                Spacer(minLength: 8)
                Text(LivePrice.attribution)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .groupedCard()
        .padding(.horizontal, 20)
    }
}
