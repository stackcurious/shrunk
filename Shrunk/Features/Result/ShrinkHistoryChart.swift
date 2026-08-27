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
        VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.sm) {
            HStack {
                Text("SIZE HISTORY")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(Color.smoke)
                Spacer()
                if let selected {
                    Text("\(selected.quantity.formattedQuantity(unit: selected.unit)) · \(selected.date, format: .dateTime.year().month(.abbreviated))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.ink)
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
        .padding(ShrunkTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ShrunkTheme.Radius.md, style: .continuous)
                .stroke(Color.border, lineWidth: 1)
        )
    }

    // MARK: - Pro affordance

    private var upgradeRow: some View {
        Button {
            onUpgrade?()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .bold))
                Text("See full history with Pro")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(hiddenCount) more")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Color.smoke)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Color.smoke)
            }
            .foregroundStyle(Color.shrunkRedDark)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .background(Color.shrunkRedLight)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
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
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.ink)
                        .padding(.leading, 4)
                }
            }
        }
        .chartXAxis {
            AxisMarks(position: .bottom) { _ in
                AxisGridLine().foregroundStyle(Color.border)
                AxisValueLabel().font(.system(size: 10))
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic) { _ in
                AxisValueLabel(format: .dateTime.year().month(.abbreviated))
                    .font(.system(size: 10))
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
        HStack(spacing: ShrunkTheme.Spacing.md) {
            sideCell(record: history[0], label: "Before", tone: .good)
            Image(systemName: "arrow.right")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.smoke)
            sideCell(record: history[1], label: "Now", tone: .alert)
        }
    }

    private func sideCell(record: SizeRecord, label: String, tone: StatBoxTone) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.5)
                .foregroundStyle(Color.smoke)
            Text(record.quantity.formattedQuantity(unit: record.unit))
                .font(.shrunkMonoNumber)
                .foregroundStyle(tone == .alert ? Color.shrunkRedDark : Color.verdictGood)
            Text(record.date, format: .dateTime.year().month(.abbreviated))
                .font(.system(size: 11))
                .foregroundStyle(Color.smoke)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ShrunkTheme.Spacing.sm)
        .background(tone == .alert ? Color.shrunkRedLight : Color(hex: "E8F5EE"))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
}
