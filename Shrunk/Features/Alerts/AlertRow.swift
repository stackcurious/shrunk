import SwiftUI

struct AlertRow: View {
    let alert: ShrinkAlert
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: ShrunkTheme.Spacing.md) {
                glyph
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(alert.productName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.ink)
                            .lineLimit(1)
                        if !alert.isRead {
                            Circle()
                                .fill(Color.shrunkRed)
                                .frame(width: 6, height: 6)
                        }
                    }
                    Text(alert.headline)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.smoke)
                        .lineLimit(2)
                    Text(alert.createdAt, format: .relative(presentation: .named))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.smokeSoft)
                }
                Spacer()
                if alert.kind.isConfirmedShrink, alert.shrinkPercent != 0 {
                    Text(alert.shrinkPercent.formattedPercentChange(decimals: 1))
                        .font(.system(size: 12, weight: .heavy, design: .monospaced))
                        .foregroundStyle(Color.shrunkRedDark)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.shrunkRedLight)
                        .clipShape(Capsule())
                }
            }
            .padding(ShrunkTheme.Spacing.md)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous)
                    .stroke(borderColor, lineWidth: borderWidth)
            )
            .shrunkElevation(ShrunkTheme.Elevation.whisper)
        }
        .buttonStyle(.plain)
    }

    private var glyph: some View {
        ZStack {
            Circle()
                .fill(dotColor.opacity(0.14))
                .frame(width: 36, height: 36)
            Image(systemName: glyphSymbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(dotColor)
        }
    }

    private var glyphSymbol: String {
        switch alert.kind {
        case .newShrink, .sizeDrop: return "exclamationmark.triangle.fill"
        case .unconfirmed:          return "questionmark"
        case .stable:                return "checkmark"
        case .priceHike:            return "chart.line.uptrend.xyaxis"
        case .verifiedCase:         return "checkmark.seal.fill"
        case .digest:                return "calendar"
        }
    }

    private var dotColor: Color {
        switch alert.kind {
        case .newShrink, .sizeDrop:      return .shrunkRed
        case .unconfirmed, .priceHike:   return .verdictWarn
        case .stable, .verifiedCase:     return .verdictGood
        case .digest:                    return .shrunkRed
        }
    }

    private var borderColor: Color {
        switch alert.kind {
        case .newShrink, .sizeDrop:    return .shrunkRed.opacity(0.35)
        case .unconfirmed, .priceHike: return .verdictWarn.opacity(0.25)
        case .stable, .verifiedCase, .digest: return .borderSoft
        }
    }

    private var borderWidth: CGFloat {
        alert.kind.isConfirmedShrink ? 1.5 : 0.5
    }
}
