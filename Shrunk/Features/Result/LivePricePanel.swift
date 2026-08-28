import SwiftUI

/// Live shelf price at the user's store. Kroger's terms require the
/// attribution wherever their data appears (spec §9).
struct LivePricePanel: View {
    let state: LivePriceState
    let storeName: String
    /// Price, was-price, promo flag and stock pill are four things on one line.
    /// Past the first accessibility size they get their own lines instead of
    /// each breaking mid-word ("$1. 67", "Sto ck un- known") — review B3.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        switch state {
        case .hidden:
            EmptyView()
        case .loading:
            card(showsAttribution: false) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking \(storeName.isEmpty ? "your store" : storeName)…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        case .unavailable:
            card(showsAttribution: false) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Store prices unavailable right now")
                        .font(.subheadline.weight(.semibold))
                    Text("The verdict and size history above don't need them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        case .loaded(let live):
            card(showsAttribution: true) { loaded(live) }
        }
    }

    @ViewBuilder
    private func loaded(_ live: LivePrice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            wrapping(spacing: 8) {
                Text(live.effectivePrice?.formattedPrice() ?? "—")
                    .font(.title.bold())
                    .monospacedDigit()
                    .foregroundStyle(live.effectivePrice == nil ? Color.secondary : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if live.isOnPromo, let regular = live.regular {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
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
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                stockPill(live.stockState, label: live.stockLabel)
            }

            wrapping(spacing: 16) {
                if let size = live.size, !size.isEmpty {
                    detail(label: "Size", value: size)
                }
                if let perOz = costPerOunce(live) {
                    detail(label: "Cost / oz", value: perOz.formattedCostPerUnit())
                }
            }
        }
    }

    /// A row until the text gets big, then a column.
    private func wrapping<Content: View>(
        spacing: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: spacing))
        return layout { content() }
    }

    /// Four states, four appearances. Green is a claim we can only make when
    /// the store said "HIGH" or "LOW"; an unrecognised or missing level gets
    /// the neutral fill so "Stock unknown" never reads as "it's there".
    private func stockPill(_ state: StockState, label: String) -> some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(stockForeground(state))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(stockBackground(state), in: Capsule())
    }

    private func stockForeground(_ state: StockState) -> Color {
        switch state {
        case .inStock:    return .verdictGoodDeep
        case .low:        return .verdictWarnDeep
        case .outOfStock: return .shrunkRedDark
        case .unknown:    return Color(.label)
        }
    }

    private func stockBackground(_ state: StockState) -> Color {
        switch state {
        case .inStock:    return .verdictGoodTint
        case .low:        return .verdictWarnTint
        case .outOfStock: return .shrunkRedLight
        case .unknown:    return Color(.tertiarySystemFill)
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

    /// The attribution belongs to Kroger *data*, so it only rides along when
    /// there is some — a spinner or an "unavailable" card has nothing to
    /// attribute (review N7).
    private func card<Content: View>(
        showsAttribution: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            wrapping(spacing: 8) {
                Text(storeName.isEmpty ? "At your store" : storeName)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                if showsAttribution {
                    Text(LivePrice.attribution)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
        .groupedCard()
        .padding(.horizontal, 20)
    }
}
