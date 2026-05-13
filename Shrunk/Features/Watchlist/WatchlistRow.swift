import SwiftUI

struct WatchlistRow: View {
    let watched: WatchedProduct
    let onTap: () -> Void
    let onToggleAlert: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: ShrunkTheme.Spacing.md) {
                statusGlyph

                VStack(alignment: .leading, spacing: 3) {
                    Text(watched.productName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(watched.lastKnownSize.formattedQuantity(unit: watched.lastKnownUnit))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.inkSubtle)
                        Text("·")
                            .foregroundStyle(Color.smokeSoft)
                        Text(daysAgoText)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.smoke)
                    }
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { watched.alertEnabled },
                    set: { _ in onToggleAlert() }
                ))
                .labelsHidden()
                .tint(Color.shrunkRed)
            }
            .padding(ShrunkTheme.Spacing.md)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous)
                    .stroke(Color.borderSoft, lineWidth: 0.5)
            )
            .shrunkElevation(ShrunkTheme.Elevation.whisper)
        }
        .buttonStyle(.plain)
    }

    private var statusGlyph: some View {
        ZStack {
            Circle()
                .fill(statusColor.opacity(0.14))
                .frame(width: 40, height: 40)
            Image(systemName: watched.alertEnabled ? "bell.fill" : "bell.slash.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(statusColor)
        }
    }

    private var statusColor: Color {
        watched.alertEnabled ? .verdictGood : .smoke
    }

    private var daysAgoText: String {
        let days = max(0, Calendar.current.dateComponents([.day], from: watched.lastChecked, to: Date()).day ?? 0)
        if days == 0 { return "checked today" }
        if days == 1 { return "yesterday" }
        return "\(days)d ago"
    }
}
