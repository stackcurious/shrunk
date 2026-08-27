import SwiftUI
import StoreKit

// MARK: - View model

@MainActor
final class ProPaywallViewModel: ObservableObject {
    enum Plan: String, CaseIterable, Identifiable {
        case yearly, monthly
        var id: String { rawValue }
    }

    /// Yearly is preselected (spec §7).
    @Published var selectedPlan: Plan = .yearly

    /// Spec prices, shown until StoreKit answers so the paywall never flashes
    /// an empty button. StoreKit is authoritative once `apply` runs.
    @Published private(set) var monthlyDisplayPrice: String = "$2.99"
    @Published private(set) var yearlyDisplayPrice: String = "$14.99"
    @Published private(set) var savingsBadge: String? = "Save 58%"
    @Published private(set) var isTrialEligible: Bool = true

    func apply(
        monthlyDisplayPrice: String?,
        monthlyPrice: Decimal?,
        yearlyDisplayPrice: String?,
        yearlyPrice: Decimal?,
        isTrialEligible: Bool
    ) {
        if let monthlyDisplayPrice { self.monthlyDisplayPrice = monthlyDisplayPrice }
        if let yearlyDisplayPrice { self.yearlyDisplayPrice = yearlyDisplayPrice }
        self.isTrialEligible = isTrialEligible

        if let monthlyPrice, let yearlyPrice,
           let percent = Self.savingsPercent(monthlyPrice: monthlyPrice, yearlyPrice: yearlyPrice) {
            savingsBadge = "Save \(percent)%"
        } else if monthlyPrice != nil || yearlyPrice != nil {
            savingsBadge = nil
        }
    }

    /// How much cheaper a year of `yearly` is than twelve months of `monthly`.
    /// $2.99 × 12 = $35.88 vs $14.99 → 58%.
    static func savingsPercent(monthlyPrice: Decimal, yearlyPrice: Decimal) -> Int? {
        let annualized = monthlyPrice * 12
        guard annualized > 0, yearlyPrice < annualized else { return nil }
        let ratio = (annualized - yearlyPrice) / annualized
        let percent = NSDecimalNumber(decimal: ratio).doubleValue * 100
        return Int(percent.rounded())
    }

    /// The trial rides on the yearly product only.
    var trialAppliesToSelection: Bool {
        isTrialEligible && selectedPlan == .yearly
    }

    var ctaTitle: String {
        if trialAppliesToSelection { return "Start 7-day free trial" }
        return selectedPlan == .yearly
            ? "Subscribe for \(yearlyDisplayPrice)/year"
            : "Subscribe for \(monthlyDisplayPrice)/month"
    }

    var fineprint: String {
        if trialAppliesToSelection {
            return "7 days free, then \(yearlyDisplayPrice)/year. Cancel anytime in Settings."
        }
        return selectedPlan == .yearly
            ? "\(yearlyDisplayPrice)/year. Cancel anytime in Settings."
            : "\(monthlyDisplayPrice)/month. Cancel anytime in Settings."
    }

    /// App Review 3.1.2's required auto-renewal disclosure, verbatim from
    /// `docs/APP_STORE_LISTING.md:97`, so the app and the listing can't
    /// drift. Rendered in both presentations of `ProPaywallContent` — the
    /// Settings sheet and the onboarding paywall step.
    static let autoRenewalDisclosure = "Payment is charged to your Apple Account at confirmation of purchase. The subscription renews automatically unless auto-renew is turned off at least 24 hours before the end of the current period. Your account is charged for renewal within 24 hours before the current period ends. Any unused portion of a free trial is forfeited when you purchase a subscription."

    /// What to tell the user once `StoreKitService.restore()` finishes. `nil`
    /// when restore actually found an active subscription — the sheet
    /// dismisses on its own via `isProUser`, so no message is needed.
    static func restoreOutcomeMessage(isPro: Bool, error: String?) -> String? {
        guard !isPro else { return nil }
        guard let error, !error.isEmpty else { return "No purchases to restore." }
        return "No purchases to restore. \(error)"
    }
}

// MARK: - Sheet

struct ProPaywallView: View {
    @EnvironmentObject private var storeKit: StoreKitService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ProPaywallContent()
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
                        .accessibilityLabel("Close")
                    }
                }
        }
        .onChange(of: storeKit.isProUser) { _, isPro in
            if isPro { dismiss() }
        }
    }
}

// MARK: - Shared body

/// The paywall itself. Used as a sheet by `ProPaywallView` and inline as the
/// final onboarding step, where `skipTitle`/`onSkip` add the free-tier exit.
struct ProPaywallContent: View {
    @EnvironmentObject private var storeKit: StoreKitService
    @Environment(\.openURL) private var openURL
    @StateObject private var vm = ProPaywallViewModel()

    private let skipTitle: String?
    private let onSkip: (() -> Void)?

    @State private var purchaseError: String?
    @State private var restoreMessage: String?

    init(skipTitle: String? = nil, onSkip: (() -> Void)? = nil) {
        self.skipTitle = skipTitle
        self.onSkip = onSkip
    }

    var body: some View {
        ScrollView {
            VStack(spacing: ShrunkTheme.Spacing.lg) {
                hero
                    .padding(.top, ShrunkTheme.Spacing.md)
                if vm.isTrialEligible {
                    trialCallout
                        .padding(.horizontal, ShrunkTheme.Spacing.lg)
                }
                planPicker
                    .padding(.horizontal, ShrunkTheme.Spacing.lg)
                valueProps
                    .padding(.horizontal, ShrunkTheme.Spacing.lg)
                ctaSection
                    .padding(.horizontal, ShrunkTheme.Spacing.lg)
                legal
                    .padding(.horizontal, ShrunkTheme.Spacing.lg)
            }
            .padding(.bottom, ShrunkTheme.Spacing.xl)
        }
        .scrollIndicators(.hidden)
        .task { await load() }
        .alert(
            "Couldn't complete purchase",
            isPresented: Binding(get: { purchaseError != nil }, set: { if !$0 { purchaseError = nil } }),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(purchaseError ?? "") }
        )
        .alert(
            "Restore purchases",
            isPresented: Binding(get: { restoreMessage != nil }, set: { if !$0 { restoreMessage = nil } }),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(restoreMessage ?? "") }
        )
    }

    private func load() async {
        if storeKit.yearlyProduct == nil || storeKit.monthlyProduct == nil {
            await storeKit.loadProducts()
        }
        await storeKit.refreshTrialEligibility()
        vm.apply(
            monthlyDisplayPrice: storeKit.monthlyProduct?.displayPrice,
            monthlyPrice: storeKit.monthlyProduct?.price,
            yearlyDisplayPrice: storeKit.yearlyProduct?.displayPrice,
            yearlyPrice: storeKit.yearlyProduct?.price,
            isTrialEligible: storeKit.isTrialEligible
        )
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: ShrunkTheme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(LinearGradient.shrunkRedDiagonal)
                    .frame(width: 110, height: 110)
                    .shrunkElevation(ShrunkTheme.Elevation.float)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(spacing: 4) {
                Text("Shrunk Pro")
                    .font(.shrunkDisplay)
                    .foregroundStyle(Color.ink)
                Text("Catch every shrink on the shelf you actually shop.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.smoke)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: Trial callout

    private var trialCallout: some View {
        HStack(spacing: ShrunkTheme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(Color.verdictGoodTint)
                    .frame(width: 44, height: 44)
                Image(systemName: "gift.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.verdictGood)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Your first 7 days are free")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(Color.ink)
                Text("On the yearly plan. Cancel any time before it ends and you pay nothing.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.smoke)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(ShrunkTheme.Spacing.md)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous)
                .stroke(Color.verdictGood.opacity(0.25), lineWidth: 0.5)
        )
        .shrunkElevation(ShrunkTheme.Elevation.whisper)
    }

    // MARK: Plans

    private var planPicker: some View {
        VStack(spacing: 10) {
            planRow(
                plan: .yearly,
                title: "Yearly",
                price: "\(vm.yearlyDisplayPrice)/year",
                caption: vm.isTrialEligible ? "7 days free, then billed yearly" : "Billed once a year",
                badge: vm.savingsBadge
            )
            planRow(
                plan: .monthly,
                title: "Monthly",
                price: "\(vm.monthlyDisplayPrice)/month",
                caption: "Billed every month",
                badge: nil
            )
        }
    }

    private func planRow(plan: ProPaywallViewModel.Plan, title: String, price: String, caption: String, badge: String?) -> some View {
        let isSelected = vm.selectedPlan == plan
        let accessibilityLabel = [badge, title, price, caption].compactMap { $0 }.joined(separator: ", ")
        return Button {
            vm.selectedPlan = plan
        } label: {
            HStack(spacing: ShrunkTheme.Spacing.md) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.shrunkRed : Color.smokeSoft)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 16, weight: .heavy))
                            .foregroundStyle(Color.ink)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.verdictGood)
                                .clipShape(Capsule())
                        }
                    }
                    Text(caption)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.smoke)
                }
                Spacer(minLength: 0)
                Text(price)
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.ink)
            }
            .padding(ShrunkTheme.Spacing.md)
            .background(isSelected ? Color.shrunkRedLight : Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous)
                    .stroke(isSelected ? Color.shrunkRed : Color.borderSoft,
                            lineWidth: isSelected ? 2 : 0.5)
            )
            .shrunkElevation(isSelected ? ShrunkTheme.Elevation.card : ShrunkTheme.Elevation.whisper)
            .animation(.spring(response: 0.3, dampingFraction: 0.78), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: Value props

    private var valueProps: some View {
        VStack(spacing: 8) {
            valueRow(icon: "bell.badge.fill", color: .shrunkRed,
                     title: "Watchlist alerts",
                     body: "Push the moment a watched product shrinks or its price per unit jumps 5%.")
            valueRow(icon: "calendar.badge.clock", color: .verdictWarn,
                     title: "Weekly digest",
                     body: "What shrank this week in the categories you buy.")
            valueRow(icon: "list.bullet.rectangle.fill", color: .verdictGood,
                     title: "Every alternative, ranked",
                     body: "Cheapest per unit, in stock, at your store — not just the first three.")
            valueRow(icon: "chart.xyaxis.line", color: .shrunkRedDark,
                     title: "Full size and price history",
                     body: "Every observation we hold, not just the latest before and after.")
            valueRow(icon: "shield.checkered", color: .verdictGood,
                     title: "Real savings dashboard",
                     body: "What each shrink actually costs you a year, from observed sizes and prices.")
        }
    }

    private func valueRow(icon: String, color: Color, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: ShrunkTheme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color.opacity(0.14))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text(body)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.smoke)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(ShrunkTheme.Spacing.md)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ShrunkTheme.Radius.md, style: .continuous)
                .stroke(Color.borderSoft, lineWidth: 0.5)
        )
    }

    // MARK: CTA

    @ViewBuilder
    private var ctaSection: some View {
        if storeKit.yearlyProduct == nil, storeKit.monthlyProduct == nil, let loadError = storeKit.loadError {
            loadErrorState(message: loadError)
        } else {
            VStack(spacing: 10) {
                ShrunkButton(vm.ctaTitle, icon: "lock.open.fill", isLoading: storeKit.purchaseInProgress) {
                    Task { await buy() }
                }
                if let skipTitle, let onSkip {
                    Button(skipTitle) { onSkip() }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.smoke)
                }
            }
        }
    }

    private func loadErrorState(message: String) -> some View {
        VStack(spacing: 10) {
            VStack(spacing: 4) {
                Text("Couldn't load plans")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(Color.ink)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.smoke)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ShrunkButton("Retry", icon: "arrow.clockwise", isLoading: storeKit.purchaseInProgress) {
                Task { await load() }
            }
            if let skipTitle, let onSkip {
                Button(skipTitle) { onSkip() }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.smoke)
            }
        }
    }

    private func buy() async {
        let product = vm.selectedPlan == .yearly ? storeKit.yearlyProduct : storeKit.monthlyProduct
        guard let product else {
            purchaseError = StoreKitError.productNotLoaded.errorDescription
            return
        }
        do {
            try await storeKit.purchase(product)
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    // MARK: Legal

    private var legal: some View {
        VStack(spacing: 8) {
            Button("Restore purchases") {
                Task {
                    await storeKit.restore()
                    restoreMessage = ProPaywallViewModel.restoreOutcomeMessage(
                        isPro: storeKit.isProUser,
                        error: storeKit.loadError
                    )
                }
            }
            .disabled(storeKit.purchaseInProgress)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.smoke)

            HStack(spacing: 16) {
                Button("Terms") {
                    if let url = URL(string: "https://stackcurious.com/shrunk/terms") { openURL(url) }
                }
                Button("Privacy") {
                    if let url = URL(string: "https://stackcurious.com/shrunk/privacy") { openURL(url) }
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.smoke)

            Text(vm.fineprint)
                .font(.system(size: 11))
                .foregroundStyle(Color.smokeSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(ProPaywallViewModel.autoRenewalDisclosure)
                .font(.system(size: 11))
                .foregroundStyle(Color.smokeSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("Independent. No brand pays us. Ever.")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.shrunkRed)
        }
        .padding(.top, ShrunkTheme.Spacing.sm)
    }
}

#Preview {
    ProPaywallView()
        .environmentObject(StoreKitService.shared)
}
