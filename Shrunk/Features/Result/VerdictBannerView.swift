import SwiftUI

struct VerdictBannerView: View {
    let verdict: ShrinkRecord.ShrinkVerdict
    let percentChange: Double
    let subline: String?

    var body: some View {
        HStack(alignment: .center, spacing: ShrunkTheme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 56, height: 56)
                Image(systemName: iconName)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let subline {
                    Text(subline)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ShrunkTheme.Spacing.lg)
        .padding(.vertical, ShrunkTheme.Spacing.lg)
        .frame(maxWidth: .infinity)
        .background(background)
    }

    // MARK: - Style mapping

    private var headline: String {
        switch verdict {
        case .significantShrink, .moderateShrink, .minorShrink:
            return "Shrunk \(formatted(absPercent))"
        case .unchanged:
            return "Unchanged"
        case .grew:
            return "Grew \(formatted(percentChange))"
        case .insufficientData:
            return "Not enough data yet"
        }
    }

    private var iconName: String {
        switch verdict {
        case .significantShrink: return "arrow.down.right.circle.fill"
        case .moderateShrink:    return "arrow.down.right.circle.fill"
        case .minorShrink:       return "arrow.down.right.circle"
        case .unchanged:         return "checkmark.circle.fill"
        case .grew:              return "arrow.up.right.circle.fill"
        case .insufficientData:  return "questionmark.circle"
        }
    }

    private var background: Color {
        switch verdict {
        case .significantShrink: return .verdictBad
        case .moderateShrink:    return .verdictWarn
        case .minorShrink:       return .verdictWarn
        case .unchanged:         return .verdictGood
        case .grew:              return .verdictGood
        case .insufficientData:  return Color(hex: "888780")
        }
    }

    // MARK: -

    private var absPercent: Double { abs(percentChange) }

    private func formatted(_ p: Double) -> String {
        if p < 10 {
            return String(format: "%.1f%%", p)
        }
        return String(format: "%.0f%%", p)
    }
}

#Preview {
    VStack(spacing: 0) {
        VerdictBannerView(verdict: .significantShrink, percentChange: -12.5, subline: "Price unchanged since 2021")
        VerdictBannerView(verdict: .moderateShrink, percentChange: -7.0, subline: "32 oz → 30 oz")
        VerdictBannerView(verdict: .minorShrink, percentChange: -2.5, subline: nil)
        VerdictBannerView(verdict: .unchanged, percentChange: 0, subline: "Same size since 2019")
        VerdictBannerView(verdict: .grew, percentChange: 6.4, subline: "Brand added more product")
        VerdictBannerView(verdict: .insufficientData, percentChange: 0, subline: "We only have one snapshot for this product")
    }
}
