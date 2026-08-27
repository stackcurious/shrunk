import SwiftUI

/// One alert as an inset-grouped list cell.
struct AlertRow: View {
    let alert: ShrinkAlert
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: glyphSymbol)
                    .font(.body)
                    .foregroundStyle(tint)
                    .frame(width: 24)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(alert.productName)
                            .font(.body)
                            .lineLimit(1)
                        if !alert.isRead {
                            Circle()
                                .fill(Color.shrunkRed)
                                .frame(width: 7, height: 7)
                                .accessibilityLabel("Unread")
                        }
                    }
                    Text(alert.headline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(alert.createdAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 8)

                if alert.kind.isConfirmedShrink, alert.shrinkPercent != 0 {
                    Text(alert.shrinkPercent.formattedPercentChange(decimals: 1))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.shrunkRedDark)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var glyphSymbol: String {
        switch alert.kind {
        case .newShrink, .sizeDrop: return "exclamationmark.triangle.fill"
        case .unconfirmed:          return "questionmark.circle"
        case .stable:               return "checkmark.circle"
        case .priceHike:            return "chart.line.uptrend.xyaxis"
        case .verifiedCase:         return "checkmark.seal.fill"
        case .digest:               return "calendar"
        }
    }

    private var tint: Color {
        switch alert.kind {
        case .newShrink, .sizeDrop:      return .shrunkRed
        case .unconfirmed, .priceHike:   return .verdictWarn
        case .stable, .verifiedCase:     return .verdictGood
        case .digest:                    return .shrunkRed
        }
    }
}
