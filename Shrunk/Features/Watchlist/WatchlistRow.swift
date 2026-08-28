import SwiftUI

/// One inset-grouped list cell: status glyph, product, and the per-product
/// alert `Toggle`. The row is a plain `HStack` rather than a `Button` so the
/// toggle keeps its own hit target — the tap target for opening the product is
/// the rest of the cell.
struct WatchlistRow: View {
    let watched: WatchedProduct
    let onTap: () -> Void
    let onToggleAlert: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: watched.alertEnabled ? "bell.fill" : "bell.slash.fill")
                    .font(.body)
                    .foregroundStyle(watched.alertEnabled ? Color.verdictGood : Color.secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(watched.productName)
                        .font(.body)
                        .lineLimit(1)
                    Text("\(watched.lastKnownSize.formattedQuantity(unit: watched.lastKnownUnit)) · \(daysAgoText)")
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            // A tap gesture is invisible to assistive technology: without
            // these VoiceOver never announces the row as a button and Switch
            // Control / Full Keyboard Access cannot activate it (review S16).
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, onTap)

            Toggle("Alerts for \(watched.productName)", isOn: Binding(
                get: { watched.alertEnabled },
                set: { _ in onToggleAlert() }
            ))
            .labelsHidden()
        }
    }

    private var daysAgoText: String {
        let days = max(0, Calendar.current.dateComponents([.day], from: watched.lastChecked, to: Date()).day ?? 0)
        if days == 0 { return "checked today" }
        if days == 1 { return "yesterday" }
        return "\(days)d ago"
    }
}
