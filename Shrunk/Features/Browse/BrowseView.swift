import SwiftUI

struct BrowseView: View {
    @StateObject private var vm = BrowseViewModel()
    @EnvironmentObject private var storeKit: StoreKitService
    @State private var presentedRecord: ShrinkRecord?
    @State private var presentedCategory: BrowseViewModel.BrowseCategory?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)

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
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .refreshable {
                await vm.refresh()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Browse")
        }
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
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading the latest shrinkflation cases…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func errorPlaceholder(message: String) -> some View {
        ContentUnavailableView {
            Label("Can't reach the feed", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        }
    }

    // MARK: - Trending

    private var trendingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "Trending shrinks", subtitle: "Tap any to see the receipts")
                .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(vm.trending, id: \.product.id) { record in
                        Button {
                            presentedRecord = record
                        } label: {
                            TrendingCard(record: record)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Categories

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "Categories", subtitle: nil)
                .padding(.horizontal, 20)
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
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Hall of shame

    private var hallOfShameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "Hall of shame", subtitle: "Worst offenders, ranked")
                .padding(.horizontal, 20)
            VStack(spacing: 0) {
                ForEach(Array(vm.hallOfShame.enumerated()), id: \.element.product.id) { idx, record in
                    Button { presentedRecord = record } label: {
                        ShameRow(rank: idx + 1, record: record)
                    }
                    .buttonStyle(.plain)
                    if idx < vm.hallOfShame.count - 1 {
                        Divider().padding(.leading, 68)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 20)
        }
    }

    private func sectionHeader(title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.title3.bold())
            if let subtitle {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Trending card

private struct TrendingCard: View {
    let record: ShrinkRecord

    /// Grows with the text it holds instead of clipping it. Capped so one card
    /// never fills the whole row — the point of the strip is that there is
    /// another card to the right.
    @ScaledMetric(relativeTo: .subheadline) private var cardWidth: CGFloat = 320

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ShrinkMeter(
                percentChange: record.shrinkPercent,
                verdict: record.verdict,
                size: .compact
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(record.product.category)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(record.product.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let prev = record.previousSize, let curr = record.currentSize {
                    Text("\(prev.quantity.formattedQuantity(unit: prev.unit)) → \(curr.quantity.formattedQuantity(unit: curr.unit))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ProductImage(url: record.product.imageURL, size: 56, cornerRadius: 10)
        }
        .padding(14)
        // Was a hard 320 × 132: at an accessibility size the name clipped to
        // "Tropi can…" and the meter caption to "S…" (review B3). Height is
        // now intrinsic and the width scales with the text.
        .frame(width: min(cardWidth, 460), alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Category tile

private struct CategoryTile: View {
    let category: BrowseViewModel.BrowseCategory
    let count: Int

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: category.icon)
                .font(.title2)
                .foregroundStyle(Color.shrunkRed)
                .frame(height: 30)
            Text(category.rawValue)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(count == 0 ? "Tap to scan" : "\(count) case\(count == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Hall of shame row

struct ShameRow: View {
    let rank: Int
    let record: ShrinkRecord

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(rank)")
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(rank <= 3 ? Color.shrunkRed : Color.secondary)
                .frame(width: 20, alignment: .center)

            ProductImage(url: record.product.imageURL, size: 44, cornerRadius: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(record.product.name)
                    .font(.subheadline)
                    .lineLimit(1)
                if let prev = record.previousSize, let curr = record.currentSize {
                    Text("\(prev.quantity.formattedQuantity(unit: prev.unit)) → \(curr.quantity.formattedQuantity(unit: curr.unit))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)

            Text(record.shrinkPercent.formattedPercentChange(decimals: 1))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color.shrunkRedDark)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

extension ShrinkRecord: Identifiable {
    public var id: String { product.id }
}
