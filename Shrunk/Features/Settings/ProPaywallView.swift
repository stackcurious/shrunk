import SwiftUI
import StoreKit

struct ProPaywallView: View {
    @EnvironmentObject private var storeKit: StoreKitService
    @Environment(\.dismiss) private var dismiss

    /// Loaded from the onboarding profile so the payback anchor is personalized.
    /// If a user reaches the paywall before completing onboarding (edge case), we
    /// fall back to a defensible default forecast.
    @AppStorage("shrunk.onboarding_profile") private var rawProfile: String = "{}"

    @State private var purchaseError: String?
    @State private var purchaseInProgress: Bool = false

    private var forecast: SavingsForecast {
        SavingsForecast.compute(profile: OnboardingProfile.decoded(rawProfile))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ShrunkTheme.Spacing.lg) {
                    hero
                        .padding(.top, ShrunkTheme.Spacing.md)
                    paybackBanner
                        .padding(.horizontal, ShrunkTheme.Spacing.lg)
                    valueProps
                        .padding(.horizontal, ShrunkTheme.Spacing.lg)
                    ctaSection
                        .padding(.horizontal, ShrunkTheme.Spacing.lg)
                    fineprint
                        .padding(.horizontal, ShrunkTheme.Spacing.lg)
                }
                .padding(.bottom, ShrunkTheme.Spacing.xl)
            }
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
                ToolbarItem(placement: .topBarLeading) {
                    Button("Restore") {
                        Task { await storeKit.restore() }
                    }
                    .foregroundStyle(Color.smoke)
                    .font(.system(size: 14, weight: .medium))
                }
            }
        }
        .task {
            if storeKit.product == nil {
                await storeKit.loadProducts()
            }
        }
        .alert("Couldn't complete purchase",
               isPresented: Binding(get: { purchaseError != nil }, set: { if !$0 { purchaseError = nil } }),
               actions: { Button("OK", role: .cancel) {} },
               message: { Text(purchaseError ?? "") })
        .onChange(of: storeKit.isProUser) { _, isPro in
            if isPro { dismiss() }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: ShrunkTheme.Spacing.md) {
            ZStack {
                Circle()
                    .stroke(Color.shrunkRed.opacity(0.18), lineWidth: 2)
                    .frame(width: 180, height: 180)
                Circle()
                    .fill(LinearGradient.shrunkRedDiagonal)
                    .frame(width: 130, height: 130)
                    .shrunkElevation(ShrunkTheme.Elevation.float)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 6) {
                Text("Shrunk Pro")
                    .font(.shrunkDisplay)
                    .foregroundStyle(Color.ink)
                Text("Pay once. Yours forever.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.smoke)
            }
        }
    }

    // MARK: - Payback anchor

    @ViewBuilder
    private var paybackBanner: some View {
        if forecast.totalAnnual > 0 {
            HStack(spacing: ShrunkTheme.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(Color.verdictGoodTint)
                        .frame(width: 44, height: 44)
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.verdictGood)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pays for itself in \(forecast.paybackDays) day\(forecast.paybackDays == 1 ? "" : "s")")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(Color.ink)
                    Text("Based on your \(forecast.totalDisplay)/yr exposure")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.smoke)
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
    }

    // MARK: - Value props

    private var valueProps: some View {
        VStack(spacing: ShrunkTheme.Spacing.sm) {
            valueRow(icon: "bell.badge.fill", color: .shrunkRed,
                     title: "Watch any product",
                     body: "Background-checked daily. We alert you the moment one shrinks.")
            valueRow(icon: "list.bullet.rectangle.fill", color: .verdictGood,
                     title: "All alternatives, ranked",
                     body: "See every cheaper-per-ounce option in the category — not just the top two.")
            valueRow(icon: "shield.checkered", color: .verdictWarn,
                     title: "Savings dashboard",
                     body: "See exactly how much you've protected from hidden price hikes.")
        }
    }

    private func valueRow(icon: String, color: Color, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: ShrunkTheme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(color.opacity(0.14))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text(body)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.smoke)
                    .lineSpacing(2)
            }
            Spacer(minLength: 0)
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

    // MARK: - CTA

    @ViewBuilder
    private var ctaSection: some View {
        VStack(spacing: 8) {
            ShrunkButton(
                "Unlock for \(storeKit.displayPrice)",
                icon: "lock.open.fill",
                isLoading: purchaseInProgress
            ) {
                Task { await runPurchase() }
            }
            Text("One-time payment. No subscription. No auto-renew.")
                .font(.system(size: 12))
                .foregroundStyle(Color.smoke)
                .multilineTextAlignment(.center)
        }
    }

    private func runPurchase() async {
        purchaseInProgress = true
        defer { purchaseInProgress = false }
        do {
            try await storeKit.purchase()
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    // MARK: - Fineprint

    private var fineprint: some View {
        VStack(spacing: 6) {
            Text("Already bought? Tap **Restore** above.")
                .font(.system(size: 11))
                .foregroundStyle(Color.smokeSoft)
            Text("Independent. No brand pays us. Ever.")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.shrunkRed)
        }
        .multilineTextAlignment(.center)
        .padding(.top, ShrunkTheme.Spacing.sm)
    }
}
