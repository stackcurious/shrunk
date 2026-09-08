import SwiftUI
import SwiftData

struct AlertsFeedView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var storeKit: StoreKitService

    @Query(sort: \ShrinkAlert.createdAt, order: .reverse)
    private var alerts: [ShrinkAlert]

    @Query(sort: \WatchedProduct.addedAt, order: .reverse)
    private var watchlist: [WatchedProduct]

    @State private var vm: AlertsViewModel?
    @State private var showPaywall: Bool = false
    @State private var showDashboard: Bool = false
    @AppStorage("shrunk.onboarding_profile") private var rawProfile: String = "{}"

    var body: some View {
        NavigationStack {
            Group {
                if !storeKit.isProUser {
                    proGate
                } else if alerts.isEmpty {
                    emptyState
                } else {
                    feed
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Alerts")
        }
        .task {
            if vm == nil {
                vm = AlertsViewModel(context: modelContext)
            }
        }
        .sheet(isPresented: $showPaywall) {
            ProPaywallView()
        }
        .sheet(isPresented: $showDashboard) {
            SavingsDashboardView()
        }
        .sheet(item: Binding<ScannedBarcode?>(
            get: { vm?.presentedBarcode.map { ScannedBarcode(id: $0) } },
            set: { vm?.presentedBarcode = $0?.id }
        )) { wrapper in
            ResultView(barcode: wrapper.id)
        }
    }

    // MARK: - Feed

    private var feed: some View {
        List {
            Section {
                savingsRow
            }

            Section {
                ForEach(visibleAlerts) { alert in
                    AlertRow(alert: alert) {
                        vm?.markRead(alert)
                        if !alert.barcode.isEmpty {
                            vm?.presentedBarcode = alert.barcode
                        }
                    }
                }
            } header: {
                filterPicker
            } footer: {
                Text("What we caught while you weren't looking.")
            }
        }
        .listStyle(.insetGrouped)
    }

    private var visibleAlerts: [ShrinkAlert] {
        guard let vm else { return alerts }
        return vm.filtered(alerts)
    }

    private var filterPicker: some View {
        Picker("Filter alerts", selection: Binding(
            get: { vm?.selectedFilter ?? .all },
            set: { vm?.selectedFilter = $0 }
        )) {
            ForEach(AlertsViewModel.Filter.allCases) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .textCase(nil)
        .padding(.bottom, 6)
    }

    private var savingsRow: some View {
        let ledger = SavingsLedger.build(
            alerts: alerts,
            watchlist: watchlist,
            shopFrequency: OnboardingProfile.decoded(rawProfile).shopFrequency
        )
        return Button {
            showDashboard = true
        } label: {
            LabeledContent {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "shield.checkered")
                        .font(.title3)
                        .foregroundStyle(Color.verdictGood)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(savingsHeadline(ledger: ledger))
                            .font(.headline)
                            .lineLimit(2)
                        Text(ledger.entries.isEmpty
                            ? "Tap to see how the math works"
                            : "Tap for the full breakdown")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func savingsHeadline(ledger: SavingsLedger) -> String {
        if ledger.totalAnnual > 0 {
            return "Shrinkflation is costing you \(ledger.totalDisplay)/yr"
        }
        return "Watching for sneaky shrinkflation"
    }

    // MARK: - Empty / gate

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No alerts yet", systemImage: "bell")
        } description: {
            Text("Add products to your Watchlist from any scan result. We'll notify you when a background check finds a documented change.")
        }
    }

    private var proGate: some View {
        ContentUnavailableView {
            Label("Background monitoring", systemImage: "shield.fill")
        } description: {
            Text("Get notified after our periodic checks find a documented size change or Kroger price jump.")
        } actions: {
            Button("Unlock Shrunk Pro · \(storeKit.yearlyProduct?.displayPrice ?? "$14.99")") {
                showPaywall = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}
