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
                HStack(spacing: ShrunkTheme.Spacing.sm) {
                    ProgressView().controlSize(.small).tint(Color.shrunkRed)
                    Text("Checking \(storeName.isEmpty ? "your store" : storeName)…")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.smoke)
                }
            }
        case .unavailable:
            card {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Store prices unavailable right now")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.ink)
                    Text("The verdict and size history above don't need them.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.smoke)
                }
            }
        case .loaded(let live):
            card { loaded(live) }
        }
    }

    @ViewBuilder
    private func loaded(_ live: LivePrice) -> some View {
        VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let price = live.effectivePrice {
                    Text(price.formattedPrice())
                        .font(.shrunkMonoBig)
                        .foregroundStyle(Color.ink)
                } else {
                    Text("—").font(.shrunkMonoBig).foregroundStyle(Color.smoke)
                }
                if live.isOnPromo, let regular = live.regular {
                    Text(regular.formattedPrice())
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.smoke)
                        .strikethrough()
                    Text("PROMO")
                        .font(.system(size: 9, weight: .heavy))
                        .tracking(0.8)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.shrunkRed)
                        .clipShape(Capsule())
                }
                Spacer(minLength: 0)
                Text(live.stockLabel)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(live.inStock ? Color.verdictGoodDeep : Color.shrunkRedDark)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(live.inStock ? Color.verdictGoodTint : Color.shrunkRedLight)
                    .clipShape(Capsule())
            }

            HStack(spacing: ShrunkTheme.Spacing.md) {
                if let size = live.size, !size.isEmpty {
                    detail(label: "Size", value: size)
                }
                if let perOz = costPerOunce(live) {
                    detail(label: "Cost / oz", value: perOz.formattedCostPerUnit())
                }
            }
        }
    }

    /// Same oz-equivalent space the verdict uses, so the two numbers agree.
    private func costPerOunce(_ live: LivePrice) -> Double? {
        guard let price = live.effectivePrice, let quantity = live.quantity, quantity > 0, let kind = live.unitKind else { return nil }
        let unit: String
        switch kind {
        case "mass":   unit = "g"
        case "volume": unit = "ml"
        default:       unit = "count"
        }
        let normalized = ShrinkDetector.normalize(
            SizeRecord(date: Date(), quantity: quantity, unit: unit, source: "kroger")
        ).quantity
        guard normalized > 0 else { return nil }
        return price / normalized
    }

    private func detail(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.5)
                .foregroundStyle(Color.smoke)
            Text(value)
                .font(.shrunkMonoSmall)
                .foregroundStyle(Color.ink)
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.sm) {
            HStack {
                Text(storeName.isEmpty ? "AT YOUR STORE" : storeName.uppercased()).shrunkSectionLabel()
                Spacer()
                Text(LivePrice.attribution)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.smoke)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shrunkCard(radius: ShrunkTheme.Radius.lg, padding: ShrunkTheme.Spacing.md)
        .padding(.horizontal, ShrunkTheme.Spacing.lg)
    }
}
