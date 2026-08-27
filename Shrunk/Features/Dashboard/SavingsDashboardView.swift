import SwiftUI
import SwiftData

struct SavingsDashboardView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var storeKit: StoreKitService

    @Query(sort: \ShrinkAlert.createdAt, order: .reverse)
    private var alerts: [ShrinkAlert]

    @Query(sort: \WatchedProduct.addedAt, order: .reverse)
    private var watchlist: [WatchedProduct]

    @AppStorage("shrunk.onboarding_profile") private var rawProfile: String = "{}"

    @State private var showPaywall: Bool = false

    private var ledger: SavingsLedger {
        SavingsLedger.build(
            alerts: alerts,
            watchlist: watchlist,
            shopFrequency: OnboardingProfile.decoded(rawProfile).shopFrequency
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                // Minor #3: every current call site (Settings, the Alerts
                // proGate, the Watchlist hero strip) already presents this
                // sheet only when Pro, but the screen's own Pro-ness
                // shouldn't be a property of its presenters — a future deep
                // link or Browse-card route must not reach the ledger free.
                if !storeKit.isProUser {
                    proGate
                } else if ledger.entries.isEmpty {
                    ScrollView { emptyState.padding(.horizontal, 20).padding(.vertical, 32) }
                } else {
                    ScrollView {
                        VStack(spacing: 24) {
                            hero
                            methodNote
                            entriesSection
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 32)
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Savings")
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
        .sheet(isPresented: $showPaywall) {
            ProPaywallView()
        }
    }

    // MARK: - Pro gate (Minor #3)

    private var proGate: some View {
        ContentUnavailableView {
            Label("Your savings dashboard is a Pro feature", systemImage: "shield.checkered")
        } description: {
            Text("See exactly what shrinkflation costs you a year, from observed sizes and prices only.")
        } actions: {
            Button("Unlock Shrunk Pro · \(storeKit.yearlyProduct?.displayPrice ?? "$14.99")") {
                showPaywall = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 4) {
            Text("Shrinkflation costs you")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 16)
            Text(ledger.totalDisplay)
                .font(.system(size: 64, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Color.shrunkRed)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("a year, across \(ledger.entries.count) \(ledger.entries.count == 1 ? "product" : "products") you track")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var methodNote: some View {
        Text("Each product's size drop × its current price at your store × how often you shop. Observed sizes and prices only — nothing estimated.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
    }

    // MARK: - Entries

    private var entriesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Per product")
                .font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(ledger.entries.enumerated()), id: \.element.id) { idx, entry in
                    SavingsEntryRow(entry: entry)
                    if idx < ledger.entries.count - 1 {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "shield.checkered")
                .font(.system(size: 52))
                .foregroundStyle(Color.verdictGood)
            VStack(spacing: 8) {
                Text("Nothing to add up yet")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("This page only shows numbers we can back with data — a measured size drop and a real price at your store.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                howItWorksRow(
                    icon: "1.circle.fill",
                    title: "Set your store",
                    subtitle: "Settings → Store. Without a price we can't cost a shrink."
                )
                howItWorksRow(
                    icon: "2.circle.fill",
                    title: "Scan or watch what you buy",
                    subtitle: "Anything with a size history gets a verdict."
                )
                howItWorksRow(
                    icon: "3.circle.fill",
                    title: "We do the multiplication",
                    subtitle: "Size drop × price × how often you shop."
                )
            }
            .padding(.top, 8)
            .groupedCard()
        }
        .frame(maxWidth: .infinity)
    }

    private func howItWorksRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.shrunkRed)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Row

private struct SavingsEntryRow: View {
    let entry: SavingsEntry

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.productName)
                    .font(.body)
                    .lineLimit(1)
                Text("\(percentText) · \(priceText)")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                Text(SavingsLedger.currencyString(entry.annual))
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(Color.shrunkRedDark)
                Text("per year")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private var percentText: String {
        String(format: "-%.1f%%", entry.shrinkPercentAbs * 100)
    }

    private var priceText: String {
        let price = String(format: "%.2f", entry.currentPrice)
        return "at $\(price)"
    }
}
