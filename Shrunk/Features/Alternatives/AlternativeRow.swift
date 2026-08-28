import SwiftUI

/// How a mini stat reads: neutral cell, bad news, good news. Lived in
/// `StatBox.swift` next to a `StatBox` view nothing referenced; this row is now
/// its only user (review N6).
enum StatBoxTone {
    case neutral
    case alert
    case good
}

struct AlternativeRow: View {
    let alternative: Alternative
    let isBestPick: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                if isBestPick {
                    Label("Best value", systemImage: "star.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.verdictGoodSolid, in: Capsule())
                }

                HStack(alignment: .top, spacing: 12) {
                    savingsBadge
                    VStack(alignment: .leading, spacing: 2) {
                        Text(alternative.name)
                            .font(.headline)
                            .lineLimit(2)
                        Text(subtitleText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }

                statRow

                Text(alternative.verdict)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .foregroundStyle(Color(.label))
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isBestPick ? Color.verdictGood : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var subtitleText: String {
        alternative.brand.isEmpty
            ? alternative.size
            : "\(alternative.brand) · \(alternative.size)"
    }

    private var savingsBadge: some View {
        VStack(spacing: 0) {
            Text(badgeTop)
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(isCheaper ? Color.verdictGoodDeep : Color(.label))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(badgeBottom)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 56, height: 56)
        .background(isCheaper ? Color.verdictGoodTint : Color(.tertiarySystemFill),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var isCheaper: Bool {
        alternative.savingsPercent.map { $0 > 0 } == true
    }

    private var badgeTop: String {
        if let savings = alternative.savingsPercent, savings > 0 { return "-\(Int(savings.rounded()))%" }
        if let cost = alternative.costPerUnit { return cost.formattedCostPerUnit() }
        return "✓"
    }

    private var badgeBottom: String {
        if isCheaper { return "¢/oz" }
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
                miniStat(label: "Stock", value: stock, tone: Self.tone(forStockLabel: stock))
            }
        }
    }

    /// "Stock unknown" is not good news — it is no news, so it gets the neutral
    /// cell rather than the green one (review S5).
    private static func tone(forStockLabel label: String) -> StatBoxTone {
        switch label {
        case "Out of stock":         return .alert
        case "In stock", "Low stock": return .good
        default:                     return .neutral
        }
    }

    private func miniStat(label: String, value: String, tone: StatBoxTone = .neutral) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(toneColor(tone))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(toneBackground(tone), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func toneColor(_ tone: StatBoxTone) -> Color {
        switch tone {
        case .alert: return .shrunkRedDark
        case .good:  return .verdictGoodDeep
        default:     return Color(.label)
        }
    }

    private func toneBackground(_ tone: StatBoxTone) -> Color {
        switch tone {
        case .alert: return .shrunkRedLight
        case .good:  return .verdictGoodTint
        default:     return Color(.tertiarySystemFill)
        }
    }
}
