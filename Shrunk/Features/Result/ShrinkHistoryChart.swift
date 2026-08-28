import SwiftUI
import Charts

struct ShrinkHistoryChart: View {
    let history: [SizeRecord]
    let unitLabel: String
    let isPro: Bool
    let hiddenCount: Int
    let onUpgrade: (() -> Void)?

    @State private var selected: SizeRecord?

    /// Spec §3.4: Pro sees every observation, free sees the latest two.
    /// Always oldest-first, so the chart reads left to right in time.
    static func visibleHistory(_ history: [SizeRecord], isPro: Bool) -> [SizeRecord] {
        let sorted = history.sorted { $0.date < $1.date }
        guard !isPro else { return sorted }
        return Array(sorted.suffix(2))
    }

    /// How many observations the free tier is not being shown.
    static func hiddenCount(_ history: [SizeRecord], isPro: Bool) -> Int {
        isPro ? 0 : max(0, history.count - 2)
    }

    init(history: [SizeRecord], isPro: Bool, onUpgrade: (() -> Void)? = nil) {
        let visible = Self.visibleHistory(history, isPro: isPro)
        self.history = visible
        self.unitLabel = visible.first?.unit ?? "oz"
        self.isPro = isPro
        self.hiddenCount = Self.hiddenCount(history, isPro: isPro)
        self.onUpgrade = onUpgrade
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Size history")
                    .font(.headline)
                Spacer(minLength: 8)
                if let selected {
                    Text("\(selected.quantity.formattedQuantity(unit: selected.unit)) · \(selected.date, format: .dateTime.year().month(.abbreviated))")
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if history.count >= 3 {
                chart
            } else if history.count == 2 {
                beforeAfter
            } else {
                EmptyView()
            }

            if hiddenCount > 0 {
                upgradeRow
            }
        }
        .groupedCard()
    }

    // MARK: - Pro affordance

    private var upgradeRow: some View {
        Button {
            onUpgrade?()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                Text("See full history with Pro")
                Text("\(hiddenCount) more")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(onUpgrade == nil)
        .accessibilityLabel("See full history with Pro, \(hiddenCount) more observations")
    }

    // MARK: - Chart variant

    private var chart: some View {
        Chart {
            ForEach(history.indices, id: \.self) { idx in
                let record = history[idx]
                let normalized = ShrinkDetector.normalize(record).quantity
                BarMark(
                    x: .value("Size", normalized),
                    y: .value("When", record.date, unit: .month)
                )
                .foregroundStyle(barColor(at: idx))
                .cornerRadius(6)
                .annotation(position: .trailing, alignment: .leading) {
                    Text(record.quantity.formattedQuantity(unit: record.unit))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .padding(.leading, 4)
                }
            }
        }
        .chartXAxis {
            AxisMarks(position: .bottom) { _ in
                AxisGridLine()
                AxisValueLabel().font(.caption2)
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic) { _ in
                AxisValueLabel(format: .dateTime.year().month(.abbreviated))
                    .font(.caption2)
            }
        }
        .frame(height: max(140, CGFloat(history.count) * 38))
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard let plotFrame = proxy.plotFrame else { return }
                                let y = value.location.y - geo[plotFrame].origin.y
                                guard let date: Date = proxy.value(atY: y) else { return }
                                selected = history.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
                            }
                            .onEnded { _ in selected = nil }
                    )
            }
        }
    }

    private func barColor(at index: Int) -> Color {
        guard index > 0 else { return .verdictGood }
        let prev = ShrinkDetector.normalize(history[index - 1]).quantity
        let curr = ShrinkDetector.normalize(history[index]).quantity
        if curr < prev * 0.99 { return .verdictBad }
        if curr > prev * 1.01 { return .verdictGood }
        return .verdictWarn
    }

    // MARK: - Before/after variant

    private var beforeAfter: some View {
        HStack(spacing: 12) {
            sideCell(record: history[0], label: "Before", isAlert: false)
            Image(systemName: "arrow.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            sideCell(record: history[1], label: "Now", isAlert: true)
        }
    }

    private func sideCell(record: SizeRecord, label: String, isAlert: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(record.quantity.formattedQuantity(unit: record.unit))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isAlert ? Color.shrunkRedDark : Color.verdictGoodDeep)
            Text(record.date, format: .dateTime.year().month(.abbreviated))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(isAlert ? Color.shrunkRedLight : Color.verdictGoodTint,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

#Preview("Free — latest two of four") {
    ShrinkHistoryChart(
        history: [
            SizeRecord(date: .now.addingTimeInterval(-1500 * 24 * 3600), quantity: 32, unit: "oz", source: "fdc"),
            SizeRecord(date: .now.addingTimeInterval(-900 * 24 * 3600),  quantity: 30, unit: "oz", source: "fdc"),
            SizeRecord(date: .now.addingTimeInterval(-300 * 24 * 3600),  quantity: 28, unit: "oz", source: "crowd"),
            SizeRecord(date: .now,                                       quantity: 26, unit: "oz", source: "kroger")
        ],
        isPro: false,
        onUpgrade: {}
    )
    .padding()
    .background(Color(.systemGroupedBackground))
}

#Preview("Pro — all four") {
    ShrinkHistoryChart(
        history: [
            SizeRecord(date: .now.addingTimeInterval(-1500 * 24 * 3600), quantity: 32, unit: "oz", source: "fdc"),
            SizeRecord(date: .now.addingTimeInterval(-900 * 24 * 3600),  quantity: 30, unit: "oz", source: "fdc"),
            SizeRecord(date: .now.addingTimeInterval(-300 * 24 * 3600),  quantity: 28, unit: "oz", source: "crowd"),
            SizeRecord(date: .now,                                       quantity: 26, unit: "oz", source: "kroger")
        ],
        isPro: true
    )
    .padding()
    .background(Color(.systemGroupedBackground))
}
