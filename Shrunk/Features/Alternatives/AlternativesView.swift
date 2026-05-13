import SwiftUI

struct AlternativesView: View {
    @StateObject private var vm: AlternativesViewModel
    @EnvironmentObject private var storeKit: StoreKitService
    @Environment(\.dismiss) private var dismiss

    init(product: ShrunkProduct, record: ShrinkRecord, alternatives: [Alternative]) {
        _vm = StateObject(wrappedValue: AlternativesViewModel(
            product: product, record: record, alternatives: alternatives
        ))
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
                            title: "No better-value alternatives found",
                            message: "We couldn't find anything cheaper per ounce in this category right now. Try scanning more products in the same aisle."
                        )
                    } else {
                        VStack(spacing: ShrunkTheme.Spacing.md) {
                            ForEach(Array(vm.alternatives.enumerated()), id: \.element.id) { idx, alt in
                                AlternativeRow(
                                    alternative: alt,
                                    isBestPick: idx == 0,
                                    isLocked: !vm.canView(alt, isPro: storeKit.isProUser),
                                    onTap: { vm.handleTap(alt, isPro: storeKit.isProUser) }
                                )
                            }
                        }
                        .padding(.horizontal, ShrunkTheme.Spacing.lg)

                        if !storeKit.isProUser, vm.alternatives.count > 2 {
                            unlockMoreCTA
                                .padding(.horizontal, ShrunkTheme.Spacing.lg)
                        }
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
                Text("\(vm.alternatives.count - 2) more alternatives")
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
