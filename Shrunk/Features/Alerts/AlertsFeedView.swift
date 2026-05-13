import SwiftUI
import SwiftData

struct AlertsFeedView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var storeKit: StoreKitService

    @Query(sort: \ShrinkAlert.createdAt, order: .reverse)
    private var alerts: [ShrinkAlert]

    @State private var vm: AlertsViewModel?
    @State private var showPaywall: Bool = false
    @State private var showDashboard: Bool = false
    @AppStorage("shrunk.onboarding_profile") private var rawProfile: String = "{}"

    var body: some View {
        Group {
            if !storeKit.isProUser {
                proGate
            } else if alerts.isEmpty {
                emptyState
            } else {
                feed
            }
        }
        .background(Color.paper.ignoresSafeArea())
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
        ScrollView {
            VStack(spacing: ShrunkTheme.Spacing.lg) {
                ShrunkPageHeader(title: "Alerts", subtitle: "What we caught while you weren't looking")
                savingsHero
                filterChips
                VStack(spacing: 8) {
                    ForEach(visibleAlerts) { alert in
                        AlertRow(alert: alert) {
                            vm?.markRead(alert)
                            vm?.presentedBarcode = alert.barcode
                        }
                    }
                }
                .padding(.horizontal, ShrunkTheme.Spacing.lg)
            }
            .padding(.bottom, 100)
        }
        .scrollIndicators(.hidden)
    }

    private var visibleAlerts: [ShrinkAlert] {
        guard let vm else { return alerts }
        return vm.filtered(alerts)
    }

    private var savingsHero: some View {
        let ledger = SavingsLedger.build(
            alerts: alerts,
            profile: OnboardingProfile.decoded(rawProfile)
        )
        return Button {
            showDashboard = true
        } label: {
            HStack(alignment: .center, spacing: ShrunkTheme.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.18))
                        .frame(width: 56, height: 56)
                    Image(systemName: "shield.checkered")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(savingsHeadline(ledger: ledger))
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(ledger.catches.isEmpty
                        ? "Tap to see how the math works"
                        : "Tap for the full breakdown")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(ShrunkTheme.Spacing.md)
            .background(LinearGradient.verdictGoodDiagonal)
            .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous))
            .shrunkElevation(ShrunkTheme.Elevation.card)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, ShrunkTheme.Spacing.lg)
    }

    private func savingsHeadline(ledger: SavingsLedger) -> String {
        if ledger.totalProtected > 0 {
            return "You've protected \(ledger.totalDisplay) so far"
        }
        return "Watching for sneaky shrinkflation"
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(AlertsViewModel.Filter.allCases) { filter in
                    Button {
                        vm?.selectedFilter = filter
                    } label: {
                        Text(filter.rawValue)
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(vm?.selectedFilter == filter ? Color.shrunkRed : Color.surface)
                            .foregroundStyle(vm?.selectedFilter == filter ? Color.white : Color.inkSubtle)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(vm?.selectedFilter == filter ? Color.clear : Color.borderSoft,
                                            lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, ShrunkTheme.Spacing.lg)
        }
    }

    // MARK: - Empty / gate

    private var emptyState: some View {
        VStack(spacing: ShrunkTheme.Spacing.lg) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.verdictGoodTint)
                    .frame(width: 120, height: 120)
                Image(systemName: "bell")
                    .font(.system(size: 50, weight: .light))
                    .foregroundStyle(Color.verdictGood)
            }
            VStack(spacing: 8) {
                Text("No alerts yet")
                    .font(.shrunkLargeTitle)
                    .foregroundStyle(Color.ink)
                Text("Add products to your Watchlist from any scan result. We'll alert you the moment one shrinks.")
                    .font(.shrunkBody)
                    .foregroundStyle(Color.smoke)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, ShrunkTheme.Spacing.lg)
                    .lineSpacing(2)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var proGate: some View {
        VStack(spacing: ShrunkTheme.Spacing.lg) {
            Spacer()
            ZStack {
                Circle()
                    .fill(LinearGradient.shrunkRedDiagonal)
                    .frame(width: 110, height: 110)
                    .shrunkElevation(ShrunkTheme.Elevation.float)
                Image(systemName: "shield.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white)
            }
            VStack(spacing: 8) {
                Text("Real-time protection")
                    .font(.shrunkLargeTitle)
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                Text("Get notified the second any watched product shrinks. We do the watching, you keep your money.")
                    .font(.shrunkBody)
                    .foregroundStyle(Color.smoke)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, ShrunkTheme.Spacing.lg)
                    .lineSpacing(2)
            }
            ShrunkButton("Unlock Shrunk Pro · \(storeKit.product?.displayPrice ?? "$9.99")", icon: "lock.open.fill") {
                showPaywall = true
            }
            .padding(.horizontal, ShrunkTheme.Spacing.lg)
            .padding(.top, ShrunkTheme.Spacing.sm)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
