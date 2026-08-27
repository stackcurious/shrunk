import SwiftUI

struct CategoryDetailView: View {
    let category: BrowseViewModel.BrowseCategory
    let records: [ShrinkRecord]
    let onSelectRecord: (ShrinkRecord) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            header
                            rows
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 32)
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(category.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: category.icon)
                .font(.largeTitle)
                .foregroundStyle(Color.shrunkRed)
            Text(summarySubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var summarySubtitle: String {
        if records.isEmpty {
            return "No documented cases yet in this category."
        }
        let avgShrink = records.reduce(0) { $0 + abs($1.shrinkPercent) } / Double(records.count)
        let avgPctString = String(format: "%.1f%%", avgShrink * 100)
        return "\(records.count) tracked case\(records.count == 1 ? "" : "s") · avg \(avgPctString) shrink"
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(records.enumerated()), id: \.element.product.id) { idx, record in
                Button {
                    onSelectRecord(record)
                } label: {
                    ShameRow(rank: idx + 1, record: record)
                }
                .buttonStyle(.plain)
                if idx < records.count - 1 {
                    Divider().padding(.leading, 68)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing tracked here yet", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text("We haven't documented shrinkflation in \(category.rawValue.lowercased()) yet. Scan a product in this category and we'll start tracking.")
        }
    }
}
