import SwiftUI

struct BrowseView: View {
    @StateObject private var vm = BrowseViewModel()
    @EnvironmentObject private var storeKit: StoreKitService
    @State private var presentedRecord: ShrinkRecord?
    @State private var presentedCategory: BrowseViewModel.BrowseCategory?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.lg) {
                ShrunkPageHeader(title: "Browse", subtitle: subtitle)
                switch vm.loadState {
                case .loading where vm.trending.isEmpty:
                    loadingPlaceholder
                case .error(let message) where vm.trending.isEmpty:
                    errorPlaceholder(message: message)
                default:
                    trendingSection
                    categoriesSection
                    hallOfShameSection
                }
            }
            .padding(.bottom, 100)   // clearance for translucent tab bar
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await vm.refresh()
        }
        .background(Color.paper.ignoresSafeArea())
        .onAppear { vm.bootstrap() }
        .sheet(item: $presentedRecord) { record in
            ResultView(prebakedProduct: record.product, prebakedRecord: record)
        }
        .sheet(item: $presentedCategory) { category in
            CategoryDetailView(
                category: category,
                records: vm.records(in: category),
                onSelectRecord: { record in
                    presentedCategory = nil
                    // Small delay to avoid sheet-over-sheet animation glitch.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        presentedRecord = record
                    }
                }
            )
        }
    }

    // MARK: - Chrome helpers

    private var subtitle: String {
        if let updated = vm.lastUpdated {
            return "Famous shrinkflation cases · updated \(Self.relativeTimeString(updated))"
        }
        return "Famous shrinkflation cases, with the receipts"
    }

    private static func relativeTimeString(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: ShrunkTheme.Spacing.md) {
            ProgressView().controlSize(.regular).tint(Color.shrunkRed)
            Text("Loading the latest shrinkflation cases…")
                .font(.system(size: 13))
                .foregroundStyle(Color.smoke)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ShrunkTheme.Spacing.xxl)
    }

    private func errorPlaceholder(message: String) -> some View {
        VStack(spacing: ShrunkTheme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(Color.shrunkRedLight)
                    .frame(width: 80, height: 80)
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(Color.shrunkRed)
            }
            Text("Can't reach the feed")
                .font(.shrunkTitle)
                .foregroundStyle(Color.ink)
            Text(message)
                .font(.shrunkBody)
                .foregroundStyle(Color.smoke)
                .multilineTextAlignment(.center)
                .padding(.horizontal, ShrunkTheme.Spacing.lg)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ShrunkTheme.Spacing.xxl)
    }

    // MARK: - Header strip

    private var headerStrip: some View {
        HStack(spacing: ShrunkTheme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(Color.shrunkRedLight)
                    .frame(width: 52, height: 52)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.shrunkRed)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Hall of fame for sneaky brands")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text("Cases people are talking about, with the receipts.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.smoke)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .shrunkCard(radius: ShrunkTheme.Radius.lg, padding: ShrunkTheme.Spacing.md)
        .padding(.horizontal, ShrunkTheme.Spacing.lg)
    }

    // MARK: - Trending

    private var trendingSection: some View {
        VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.sm) {
            sectionHeader(title: "Trending shrinks", subtitle: "Tap any to see the receipts")
                .padding(.horizontal, ShrunkTheme.Spacing.lg)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: ShrunkTheme.Spacing.md) {
                    ForEach(vm.trending, id: \.product.id) { record in
                        Button {
                            presentedRecord = record
                        } label: {
                            TrendingCard(record: record)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, ShrunkTheme.Spacing.lg)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Categories

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.sm) {
            sectionHeader(title: "Categories", subtitle: nil)
                .padding(.horizontal, ShrunkTheme.Spacing.lg)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                spacing: 10
            ) {
                ForEach(vm.categories) { cat in
                    Button {
                        presentedCategory = cat
                    } label: {
                        CategoryTile(category: cat, count: vm.records(in: cat).count)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, ShrunkTheme.Spacing.lg)
        }
    }

    // MARK: - Hall of shame

    private var hallOfShameSection: some View {
        VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.sm) {
            sectionHeader(title: "Hall of shame", subtitle: "Worst offenders, ranked")
                .padding(.horizontal, ShrunkTheme.Spacing.lg)
            VStack(spacing: 8) {
                ForEach(Array(vm.hallOfShame.enumerated()), id: \.element.product.id) { idx, record in
                    Button { presentedRecord = record } label: {
                        ShameRow(rank: idx + 1, record: record)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, ShrunkTheme.Spacing.lg)
        }
    }

    private func sectionHeader(title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.shrunkTitle)
                .foregroundStyle(Color.ink)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.smoke)
            }
        }
    }
}

// MARK: - Trending card

private struct TrendingCard: View {
    let record: ShrinkRecord

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ShrinkMeter(
                percentChange: record.shrinkPercent,
                verdict: record.verdict,
                size: .compact
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(record.product.category.uppercased())
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.8)
                    .foregroundStyle(Color.smoke)
                Text(record.product.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let prev = record.previousSize, let curr = record.currentSize {
                    Text("\(prev.quantity.formattedQuantity(unit: prev.unit)) → \(curr.quantity.formattedQuantity(unit: curr.unit))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.smoke)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ProductImage(url: record.product.imageURL, size: 56, cornerRadius: 10)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, ShrunkTheme.Spacing.md)
        .frame(width: 320, height: 132)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous)
                .stroke(Color.borderSoft, lineWidth: 0.5)
        )
        .shrunkElevation(ShrunkTheme.Elevation.card)
    }
}

// MARK: - Category tile

private struct CategoryTile: View {
    let category: BrowseViewModel.BrowseCategory
    let count: Int

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.shrunkRedLight)
                    .frame(width: 44, height: 44)
                Image(systemName: category.icon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Color.shrunkRed)
            }
            Text(category.rawValue)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(count == 0 ? "Tap to scan" : "\(count) case\(count == 1 ? "" : "s")")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.smoke)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ShrunkTheme.Radius.md, style: .continuous)
                .stroke(Color.borderSoft, lineWidth: 0.5)
        )
        .shrunkElevation(ShrunkTheme.Elevation.whisper)
    }
}

// MARK: - Hall of shame row

struct ShameRow: View {
    let rank: Int
    let record: ShrinkRecord

    var body: some View {
        HStack(alignment: .center, spacing: ShrunkTheme.Spacing.md) {
            rankBadge

            ProductImage(url: record.product.imageURL, size: 44, cornerRadius: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.product.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                if let prev = record.previousSize, let curr = record.currentSize {
                    Text("\(prev.quantity.formattedQuantity(unit: prev.unit)) → \(curr.quantity.formattedQuantity(unit: curr.unit))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.smoke)
                }
            }
            Spacer()

            Text(record.shrinkPercent.formattedPercentChange(decimals: 1))
                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                .foregroundStyle(Color.shrunkRedDark)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.shrunkRedLight)
                .clipShape(Capsule())
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

    @ViewBuilder
    private var rankBadge: some View {
        if rank <= 3 {
            ZStack {
                Circle()
                    .fill(LinearGradient.shrunkRedDiagonal)
                    .frame(width: 38, height: 38)
                Text("#\(rank)")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
            .shrunkElevation(ShrunkTheme.Elevation.whisper)
        } else {
            ZStack {
                Circle()
                    .fill(Color.mist)
                    .frame(width: 38, height: 38)
                Text("#\(rank)")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.smoke)
            }
        }
    }
}

extension ShrinkRecord: Identifiable {
    public var id: String { product.id }
}
