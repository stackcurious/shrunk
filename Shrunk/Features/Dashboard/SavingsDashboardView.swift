import SwiftUI
import SwiftData
import Charts

struct SavingsDashboardView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \ShrinkAlert.createdAt, order: .reverse)
    private var alerts: [ShrinkAlert]

    @AppStorage("shrunk.onboarding_profile") private var rawProfile: String = "{}"

    private var ledger: SavingsLedger {
        SavingsLedger.build(
            alerts: alerts,
            profile: OnboardingProfile.decoded(rawProfile)
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ShrunkTheme.Spacing.lg) {
                    if ledger.catches.isEmpty {
                        emptyState
                            .padding(.top, ShrunkTheme.Spacing.xl)
                    } else {
                        hero
                        statsStrip
                        if !ledger.dailyTotals.isEmpty {
                            chartSection
                        }
                        catchesSection
                    }
                }
                .padding(.horizontal, ShrunkTheme.Spacing.lg)
                .padding(.bottom, ShrunkTheme.Spacing.xl)
            }
            .scrollIndicators(.hidden)
            .background(Color.paper.ignoresSafeArea())
            .navigationTitle("Savings")
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

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 4) {
            Text("PROTECTED, ANNUALIZED")
                .font(.system(size: 10, weight: .heavy))
                .tracking(1.2)
                .foregroundStyle(Color.smoke)
                .padding(.top, ShrunkTheme.Spacing.md)
            Text(ledger.totalDisplay)
                .font(.system(size: 76, weight: .heavy, design: .rounded))
                .foregroundStyle(LinearGradient.verdictGoodDiagonal)
            Text("avoided in hidden price hikes")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.smoke)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Stats strip

    private var statsStrip: some View {
        HStack(spacing: 10) {
            statCard(
                value: "\(ledger.catches.count)",
                label: ledger.catches.count == 1 ? "catch" : "catches",
                tint: .shrunkRed
            )
            statCard(
                value: ledger.thisMonthDisplay,
                label: "this month",
                tint: .verdictWarn
            )
            statCard(
                value: ledger.ongoingAnnualDisplay,
                label: "ongoing/yr",
                tint: .verdictGood
            )
        }
    }

    private func statCard(value: String, label: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label.uppercased())
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ShrunkTheme.Spacing.md)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous)
                .stroke(Color.borderSoft, lineWidth: 0.5)
        )
        .shrunkElevation(ShrunkTheme.Elevation.whisper)
    }

    // MARK: - Chart

    @ViewBuilder
    private var chartSection: some View {
        VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.sm) {
            HStack {
                Text("CUMULATIVE")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(0.8)
                    .foregroundStyle(Color.smoke)
                Spacer()
            }
            Chart {
                ForEach(ledger.dailyTotals) { point in
                    AreaMark(
                        x: .value("Date", point.date),
                        y: .value("Protected", point.cumulative)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.verdictGood.opacity(0.35), Color.verdictGood.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.monotone)
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Protected", point.cumulative)
                    )
                    .foregroundStyle(Color.verdictGood)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .interpolationMethod(.monotone)
                }
            }
            .frame(height: 160)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Color.borderSoft)
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .font(.system(size: 10))
                        .foregroundStyle(Color.smoke)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Color.borderSoft)
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(SavingsLedger.currencyString(amount))
                                .font(.system(size: 10))
                                .foregroundStyle(Color.smoke)
                        }
                    }
                }
            }
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

    // MARK: - Catches list

    private var catchesSection: some View {
        VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.sm) {
            HStack {
                Text("CAUGHT")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(0.8)
                    .foregroundStyle(Color.smoke)
                Spacer()
            }
            VStack(spacing: 8) {
                ForEach(ledger.catches) { c in
                    CatchRow(catch_: c)
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: ShrunkTheme.Spacing.lg) {
            ZStack {
                Circle()
                    .fill(Color.verdictGoodTint)
                    .frame(width: 140, height: 140)
                    .shrunkElevation(ShrunkTheme.Elevation.float)
                Image(systemName: "shield.checkered")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(Color.verdictGood)
            }
            VStack(spacing: 8) {
                Text("No catches yet")
                    .font(.shrunkLargeTitle)
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                Text("Once a product on your watchlist shrinks, we'll record how much we caught — and you'll see the running total here.")
                    .font(.shrunkBody)
                    .foregroundStyle(Color.smoke)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, ShrunkTheme.Spacing.md)
            }

            VStack(spacing: 12) {
                howItWorksRow(
                    icon: "1.circle.fill",
                    title: "Add products to your watchlist",
                    subtitle: "Scan anything you buy regularly"
                )
                howItWorksRow(
                    icon: "2.circle.fill",
                    title: "We check daily",
                    subtitle: "Background sweeps against Open Food Facts"
                )
                howItWorksRow(
                    icon: "3.circle.fill",
                    title: "Catches accumulate",
                    subtitle: "We multiply per-catch loss by your shop frequency to estimate yearly savings"
                )
            }
            .padding(.top, ShrunkTheme.Spacing.md)
        }
        .frame(maxWidth: .infinity)
    }

    private func howItWorksRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: ShrunkTheme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.shrunkRed)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.smoke)
                    .lineSpacing(2)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Catch row

private struct CatchRow: View {
    let catch_: SavingsCatch

    var body: some View {
        HStack(spacing: ShrunkTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(catch_.productName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(percentText)
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .foregroundStyle(Color.shrunkRedDark)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.shrunkRedLight)
                        .clipShape(Capsule())
                    Text(dateText)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.smoke)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text("+\(SavingsLedger.currencyString(catch_.estimatedAnnualSavings))")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.verdictGood)
                Text("per year")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.smoke)
            }
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

    private var percentText: String {
        String(format: "%.1f%%", abs(catch_.shrinkPercent) * 100)
    }

    private var dateText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: catch_.detectedAt)
    }
}
