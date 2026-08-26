import SwiftUI

/// Onboarding step 4: pick a Kroger store so scans show live prices. Skippable —
/// the CTA reads "Skip for now" until a store is chosen (spec §7).
struct StoreStep: View {
    @AppStorage(StorePickerViewModel.storeNameKey) private var storeName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Where do you shop?")
                    .font(.shrunkLargeTitle)
                    .foregroundStyle(Color.ink)
                Text("Pick your Kroger and every scan shows the shelf price and the real cost per ounce. You can change it any time in Settings.")
                    .font(.shrunkBody)
                    .foregroundStyle(Color.smoke)
                    .lineSpacing(3)
            }
            .padding(.horizontal, ShrunkTheme.Spacing.lg)

            if !storeName.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.verdictGoodDeep)
                    Text(storeName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.ink)
                }
                .padding(.horizontal, ShrunkTheme.Spacing.lg)
            }

            StorePickerView(embedded: true)
        }
    }
}
