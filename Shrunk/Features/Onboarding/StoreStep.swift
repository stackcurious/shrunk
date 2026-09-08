import SwiftUI

/// Onboarding step 3: pick a Kroger store so scans show live prices. Skippable
/// via the top-bar "Skip" button; the CTA reads "Use this store" once one is
/// chosen (spec §7).
struct StoreStep: View {
    @AppStorage(StorePickerViewModel.storeNameKey) private var storeName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Where do you shop?")
                    .font(.largeTitle.bold())
                Text("Pick a Kroger to add available shelf price, promotion, stock, and unit cost to scans. You can change it any time in Settings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)

            if !storeName.isEmpty {
                Label(storeName, systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color.verdictGoodDeep)
                    .padding(.horizontal, 20)
            }

            StorePickerView(embedded: true)
        }
    }
}
