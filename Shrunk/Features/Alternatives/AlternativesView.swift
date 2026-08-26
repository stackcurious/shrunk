import SwiftUI

struct AlternativesView: View {
    @StateObject private var vm: AlternativesViewModel
    @EnvironmentObject private var storeKit: StoreKitService
    @Environment(\.dismiss) private var dismiss

    init(product: ShrunkProduct, record: ShrinkRecord, result: AlternativesResult) {
        _vm = StateObject(wrappedValue: AlternativesViewModel(product: product, record: record, result: result))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ShrunkTheme.Spacing.md) {
                    headerStrip
                        .padding(.horizontal, ShrunkTheme.Spacing.lg)
                        .padding(.top, ShrunkTheme.Spacing.md)

                    if vm.alternatives.isEmpty {
                        EmptyStateView(
                            icon: "magnifyingglass",
                            title: "Nothing to compare yet",
                            message: "Set your store in Settings to see in-stock alternatives ranked by cost per ounce."
                        )
                    } else {
                        if vm.isCurated {
                            Text("Verified cases in this category")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.smoke)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, ShrunkTheme.Spacing.lg)
                        }
                        VStack(spacing: ShrunkTheme.Spacing.md) {
                            ForEach(Array(vm.alternatives.enumerated()), id: \.element.id) { idx, alt in
                                AlternativeRow(
                                    alternative: alt,
                                    isBestPick: idx == 0 && !vm.isCurated,
                                    onTap: { vm.present(alt) }
                                )
                            }
                        }
                        .padding(.horizontal, ShrunkTheme.Spacing.lg)

                        if !storeKit.isProUser, vm.hiddenCount > 0 {
                            unlockMoreCTA
                                .padding(.horizontal, ShrunkTheme.Spacing.lg)
                        }
                    }

                    if !vm.isCurated {
                        Text(LivePrice.attribution)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.smoke)
                            .frame(maxWidth: .infinity)
                            .padding(.top, ShrunkTheme.Spacing.sm)
                    }
                }
                .padding(.bottom, ShrunkTheme.Spacing.xl)
            }
            .background(Color.paper)
            .navigationTitle("Alternatives")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.shrunkRed)
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

    // MARK: - Header strip

    private var headerStrip: some View {
        HStack(alignment: .top, spacing: ShrunkTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Comparing against")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Color.smoke)
                Text(vm.headerCostPerUnitText())
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
            }
            Spacer()
            if vm.sourceRecord.verdict.isShrink {
                Text("you're overpaying")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(0.4)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.shrunkRed)
                    .clipShape(Capsule())
            }
        }
        .padding(ShrunkTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ShrunkTheme.Radius.md, style: .continuous)
                .stroke(Color.border, lineWidth: 1)
        )
    }

    private var unlockMoreCTA: some View {
        VStack(spacing: ShrunkTheme.Spacing.sm) {
            HStack(spacing: 6) {
                ProBadge(style: .pill)
                Text("\(vm.hiddenCount) more alternatives")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ink)
            }
            ShrunkButton("Unlock with Pro", icon: "lock.open.fill") {
                vm.showPaywall = true
            }
        }
        .padding(ShrunkTheme.Spacing.md)
        .frame(maxWidth: .infinity)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ShrunkTheme.Radius.md, style: .continuous)
                .stroke(Color.border, lineWidth: 1)
        )
    }

}
