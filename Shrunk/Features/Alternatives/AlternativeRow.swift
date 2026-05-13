import SwiftUI

struct AlternativeRow: View {
    let alternative: Alternative
    let isBestPick: Bool
    let isLocked: Bool
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
                    Image(systemName: isLocked ? "lock.fill" : "chevron.right")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(isLocked ? Color.shrunkRed : Color.smokeSoft)
                }

                statRow

                Text(alternative.verdict)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.inkSubtle)
                    .lineLimit(2)
            }
            .padding(ShrunkTheme.Spacing.md)
            .background(Color.surface)
            .overlay(
                isLocked
                ? AnyView(blurOverlay)
                : AnyView(EmptyView())
            )
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
                .fill(Color.verdictGoodTint)
                .frame(width: 56, height: 56)
            VStack(spacing: -1) {
                Text("-\(Int(alternative.savingsPercent.rounded()))%")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.verdictGoodDeep)
                Text("¢/oz")
                    .font(.system(size: 8, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(Color.verdictGoodDeep)
            }
        }
    }

    private var statRow: some View {
        HStack(spacing: 8) {
            miniStat(label: "Cost / oz", value: alternative.costPerUnit.formattedCostPerUnit())
            miniStat(label: "Shrunk?", value: alternative.hasShrunkBefore ? "Yes" : "No",
                     tone: alternative.hasShrunkBefore ? .alert : .good)
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

    private var blurOverlay: some View {
        ZStack {
            Color.white.opacity(0.55)
            VStack(spacing: 6) {
                ProBadge(style: .lock)
                Text("Pro to unlock")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.ink)
            }
        }
        .blur(radius: 0.6)
    }
}
