import SwiftUI

struct CategoryDetailView: View {
    let category: BrowseViewModel.BrowseCategory
    let records: [ShrinkRecord]
    let onSelectRecord: (ShrinkRecord) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ShrunkTheme.Spacing.lg) {
                    header
                        .padding(.horizontal, ShrunkTheme.Spacing.lg)
                        .padding(.top, ShrunkTheme.Spacing.md)

                    if records.isEmpty {
                        emptyState
                            .padding(.horizontal, ShrunkTheme.Spacing.lg)
                            .padding(.top, ShrunkTheme.Spacing.xl)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(Array(records.enumerated()), id: \.element.product.id) { idx, record in
                                Button {
                                    onSelectRecord(record)
                                } label: {
                                    ShameRow(rank: idx + 1, record: record)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, ShrunkTheme.Spacing.lg)
                    }
                }
                .padding(.bottom, ShrunkTheme.Spacing.xl)
            }
            .scrollIndicators(.hidden)
            .background(Color.paper.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(Color.ink)
                            .frame(width: 32, height: 32)
                            .background(Color.mist)
                            .clipShape(Circle())
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: ShrunkTheme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(Color.shrunkRedLight)
                    .frame(width: 80, height: 80)
                Image(systemName: category.icon)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color.shrunkRed)
            }
            VStack(spacing: 4) {
                Text(category.rawValue)
                    .font(.shrunkLargeTitle)
                    .foregroundStyle(Color.ink)
                Text(summarySubtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.smoke)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var summarySubtitle: String {
        if records.isEmpty {
            return "No documented cases yet in this category."
        }
        let avgShrink = records.reduce(0) { $0 + abs($1.shrinkPercent) } / Double(records.count)
        let avgPctString = String(format: "%.1f%%", avgShrink * 100)
        return "\(records.count) tracked case\(records.count == 1 ? "" : "s") · avg \(avgPctString) shrink"
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: ShrunkTheme.Spacing.lg) {
            ZStack {
                Circle()
                    .fill(Color.mist)
                    .frame(width: 120, height: 120)
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(Color.smokeSoft)
            }
            VStack(spacing: 8) {
                Text("Nothing tracked here yet")
                    .font(.shrunkTitle)
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                Text("We haven't documented shrinkflation in \(category.rawValue.lowercased()) yet. Scan a product in this category and we'll start tracking.")
                    .font(.shrunkBody)
                    .foregroundStyle(Color.smoke)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, ShrunkTheme.Spacing.md)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
