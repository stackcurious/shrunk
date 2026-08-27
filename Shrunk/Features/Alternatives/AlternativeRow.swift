import SwiftUI

struct AlternativeRow: View {
    let alternative: Alternative
    let isBestPick: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.md) {
                if isBestPick {
                    bestPickRibbon
                }

                HStack(alignment: .top, spacing: ShrunkTheme.Spacing.md) {
                    savingsBadge
                    VStack(alignment: .leading, spacing: 2) {
                        Text(alternative.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.ink)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            if !alternative.brand.isEmpty {
                                Text(alternative.brand)
                            }
                            if !alternative.brand.isEmpty {
                                Text("·")
                            }
                            Text(alternative.size)
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(Color.smoke)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(Color.smokeSoft)
                }

                statRow

                Text(alternative.verdict)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.inkSubtle)
                    .lineLimit(2)
            }
            .padding(ShrunkTheme.Spacing.md)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous)
                    .stroke(isBestPick ? Color.verdictGood.opacity(0.5) : Color.borderSoft,
                            lineWidth: isBestPick ? 1.5 : 0.5)
            )
            .shrunkElevation(ShrunkTheme.Elevation.whisper)
        }
        .buttonStyle(.plain)
    }

    private var bestPickRibbon: some View {
        HStack(spacing: 6) {
            Image(systemName: "star.fill")
                .font(.system(size: 11, weight: .heavy))
            Text("BEST VALUE")
                .font(.system(size: 10, weight: .heavy))
                .tracking(1.0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(LinearGradient.verdictGoodDiagonal)
        .clipShape(Capsule())
    }

    private var savingsBadge: some View {
        ZStack {
            Circle()
                .fill(alternative.savingsPercent.map { $0 > 0 } == true ? Color.verdictGoodTint : Color.mist)
                .frame(width: 56, height: 56)
            VStack(spacing: -1) {
                Text(badgeTop)
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(alternative.savingsPercent.map { $0 > 0 } == true ? Color.verdictGoodDeep : Color.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(badgeBottom)
                    .font(.system(size: 8, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(Color.smoke)
            }
            .padding(.horizontal, 4)
        }
    }

    private var badgeTop: String {
        if let savings = alternative.savingsPercent, savings > 0 { return "-\(Int(savings.rounded()))%" }
        if let cost = alternative.costPerUnit { return cost.formattedCostPerUnit() }
        return "✓"
    }

    private var badgeBottom: String {
        if alternative.savingsPercent.map({ $0 > 0 }) == true { return "¢/oz" }
        return alternative.source == .curated ? "verified" : "per oz"
    }

    private var statRow: some View {
        HStack(spacing: 8) {
            if let cost = alternative.costPerUnit {
                miniStat(label: "Cost / oz", value: cost.formattedCostPerUnit())
            }
            if let price = alternative.price {
                miniStat(label: "Price", value: price.formattedPrice())
            }
            if let stock = alternative.stockLabel {
                miniStat(label: "Stock", value: stock, tone: stock == "Out of stock" ? .alert : .good)
            }
        }
    }

    private func miniStat(label: String, value: String, tone: StatBoxTone = .neutral) -> some View {
        HStack(spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.5)
                .foregroundStyle(Color.smoke)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(toneColor(tone))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(toneBg(tone))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func toneColor(_ tone: StatBoxTone) -> Color {
        switch tone {
        case .alert: return .shrunkRedDark
        case .good:  return .verdictGoodDeep
        default:     return .ink
        }
    }

    private func toneBg(_ tone: StatBoxTone) -> Color {
        switch tone {
        case .alert: return .shrunkRedLight
        case .good:  return .verdictGoodTint
        default:     return .mist
        }
    }
}
