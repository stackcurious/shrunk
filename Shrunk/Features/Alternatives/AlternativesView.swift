import SwiftUI

struct AlternativesView: View {
    @StateObject private var vm: AlternativesViewModel
    @EnvironmentObject private var storeKit: StoreKitService
    @Environment(\.dismiss) private var dismiss
    @AppStorage(StorePickerViewModel.storeNameKey) private var storeName: String = ""

    init(product: ShrunkProduct, record: ShrinkRecord, result: AlternativesResult) {
        _vm = StateObject(wrappedValue: AlternativesViewModel(product: product, record: record, result: result))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    headerStrip
                        .padding(.horizontal, 20)
                        .padding(.top, 8)

                    if vm.alternatives.isEmpty {
                        EmptyStateView(
                            icon: "magnifyingglass",
                            title: "Nothing to compare yet",
                            message: emptyMessage
                        )
                    } else {
                        if vm.isCurated {
                            Text("Verified cases in this category")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                        }
                        VStack(spacing: 12) {
                            ForEach(Array(vm.alternatives.enumerated()), id: \.element.id) { idx, alt in
                                AlternativeRow(
                                    alternative: alt,
                                    isBestPick: idx == 0 && !vm.isCurated,
                                    onTap: { vm.present(alt) }
                                )
                            }
                        }
                        .padding(.horizontal, 20)

                        if !storeKit.isProUser, vm.hiddenCount > 0 {
                            unlockMoreCTA
                                .padding(.horizontal, 20)
                        }
                    }

                    if !vm.isCurated {
                        Text(LivePrice.attribution)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 8)
                    }
                }
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Alternatives")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .sheet(isPresented: $vm.showPaywall) {
            ProPaywallView()
        }
        .sheet(item: Binding<ScannedBarcode?>(
            get: { vm.presentedBarcode.map { ScannedBarcode(id: $0) } },
            set: { vm.presentedBarcode = $0?.id }
        )) { wrapper in
            ResultView(barcode: wrapper.id)
        }
    }

    /// Rule 1: never send someone off to do something they have already done.
    /// With a store set, an empty list means the shelf had nothing better —
    /// not that the app is unconfigured (review S3).
    private var emptyMessage: String {
        storeName.isEmpty
            ? "Set your Kroger in Settings to see available in-stock alternatives ranked by unit price."
            : "No cheaper option at \(storeName) right now. We'll keep checking."
    }

    // MARK: - Header strip

    private var headerStrip: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Comparing against")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(vm.headerCostPerUnitText())
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if vm.sourceRecord.verdict.isShrink {
                Text("you're overpaying")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.shrunkRed, in: Capsule())
            }
        }
        .groupedCard()
    }

    private var unlockMoreCTA: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                ProBadge(style: .pill)
                Text("\(vm.hiddenCount) more alternatives")
                    .font(.headline)
                    .monospacedDigit()
            }
            ShrunkButton("Unlock with Pro", icon: "lock.open.fill") {
                vm.showPaywall = true
            }
        }
        .frame(maxWidth: .infinity)
        .groupedCard()
    }

}
