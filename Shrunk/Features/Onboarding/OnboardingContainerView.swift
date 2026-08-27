import SwiftUI

struct OnboardingContainerView: View {
    @StateObject private var vm = OnboardingViewModel()
    @EnvironmentObject private var storeKit: StoreKitService

    @AppStorage("shrunk.onboarding_profile") private var persistedProfile: String = "{}"

    let onFinish: () -> Void

    var body: some View {
        ZStack {
            Color.paper.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                progressBar
                pageContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ctaSection
                    .padding(.horizontal, ShrunkTheme.Spacing.lg)
                    .padding(.bottom, ShrunkTheme.Spacing.lg)
            }
        }
        .onChange(of: vm.profile) { _, profile in
            persistedProfile = profile.encoded()
        }
        .onChange(of: storeKit.isProUser) { _, isPro in
            // I6: don't bounce an already-Pro user out of onboarding before
            // they've picked categories or a store — only an entitlement
            // resolved on the paywall step (i.e. an actual purchase there)
            // should finish the flow early.
            if vm.shouldAutoFinish(becauseIsPro: isPro) { finish() }
        }
    }

    private func finish() {
        persistedProfile = vm.profile.encoded()
        onFinish()
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            if vm.step == .welcome {
                HStack(spacing: 6) {
                    Image(systemName: "barcode.viewfinder")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.shrunkRed)
                    Text("SHRUNK")
                        .font(.system(size: 13, weight: .heavy))
                        .tracking(1.6)
                        .foregroundStyle(Color.ink)
                }
            } else {
                Button {
                    vm.back()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(Color.ink)
                        .frame(width: 36, height: 36)
                        .background(Color.mist)
                        .clipShape(Circle())
                }
                .accessibilityLabel("Back")
            }
            Spacer()
            if vm.step.allowsSkip {
                Button("Skip") { vm.skipStore() }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.smoke)
            }
        }
        .padding(.horizontal, ShrunkTheme.Spacing.lg)
        .frame(height: 52)
    }

    @ViewBuilder
    private var progressBar: some View {
        if vm.step.showsProgress {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.border)
                        .frame(height: 4)
                    Capsule()
                        .fill(LinearGradient.shrunkRedDiagonal)
                        .frame(width: geo.size.width * vm.progressFraction, height: 4)
                        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: vm.progressFraction)
                }
            }
            .frame(height: 4)
            .padding(.horizontal, ShrunkTheme.Spacing.lg)
            .padding(.bottom, ShrunkTheme.Spacing.md)
        } else {
            Color.clear.frame(height: 4 + ShrunkTheme.Spacing.md)
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch vm.step {
        case .welcome:    WelcomeStep()
        case .categories: CategoriesStep(vm: vm)
        case .store:      StoreStep()
        case .paywall:
            ProPaywallContent(skipTitle: "Continue with the free version") { finish() }
        }
    }

    // MARK: - CTA

    @ViewBuilder
    private var ctaSection: some View {
        if vm.step == .paywall {
            // ProPaywallContent owns its own CTA and free-tier exit.
            Color.clear.frame(height: 0)
        } else {
            ShrunkButton(ctaTitle, icon: "arrow.right", isLoading: false) {
                vm.advance()
            }
            .opacity(vm.canAdvance ? 1 : 0.35)
            .allowsHitTesting(vm.canAdvance)
            .animation(.easeOut(duration: 0.15), value: vm.canAdvance)
        }
    }

    private var ctaTitle: String {
        switch vm.step {
        case .welcome:    return "Show me how"
        case .categories: return "Continue"
        case .store:      return "Use this store"
        case .paywall:    return "Continue"
        }
    }
}

// MARK: - Step 1: WELCOME

private struct WelcomeStep: View {
    @State private var arrowDrop: CGFloat = -10

    var body: some View {
        VStack(spacing: ShrunkTheme.Spacing.xl) {
            Spacer(minLength: ShrunkTheme.Spacing.md)
            illustration
                .frame(maxWidth: .infinity)
            VStack(spacing: ShrunkTheme.Spacing.md) {
                Text("They're shrinking your groceries.")
                    .font(.shrunkLargeTitle)
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                Text("Same price. Less product. Scan a barcode and see exactly what changed.")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.smoke)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, ShrunkTheme.Spacing.md)
            }
            .padding(.horizontal, ShrunkTheme.Spacing.lg)
            Spacer()
        }
    }

    private var illustration: some View {
        ZStack {
            Circle()
                .fill(Color.shrunkRedLight)
                .frame(width: 240, height: 240)
                .blur(radius: 12)
                .opacity(0.7)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.surface)
                .frame(width: 156, height: 196)
                .rotationEffect(.degrees(-6))
                .offset(x: -22, y: 6)
                .shrunkElevation(ShrunkTheme.Elevation.card)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.surface)
                .frame(width: 156, height: 196)
                .overlay(
                    VStack(alignment: .leading, spacing: 8) {
                        Capsule().fill(Color.mist).frame(width: 80, height: 8)
                        Capsule().fill(Color.mist).frame(width: 110, height: 8)
                        Capsule().fill(Color.mist).frame(width: 60, height: 8)
                        Spacer()
                        Capsule()
                            .fill(Color.shrunkRedLight)
                            .frame(width: 90, height: 24)
                            .overlay(
                                Text("$1.89")
                                    .font(.system(size: 12, weight: .heavy, design: .monospaced))
                                    .foregroundStyle(Color.shrunkRedDark)
                            )
                    }
                    .padding(16)
                )
                .rotationEffect(.degrees(4))
                .offset(x: 18, y: -2)
                .shrunkElevation(ShrunkTheme.Elevation.card)
            ZStack {
                Circle()
                    .fill(LinearGradient.shrunkRedDiagonal)
                    .frame(width: 78, height: 78)
                    .shrunkElevation(ShrunkTheme.Elevation.float)
                Image(systemName: "arrow.down")
                    .font(.system(size: 32, weight: .black))
                    .foregroundStyle(.white)
            }
            .offset(x: 84, y: arrowDrop)
        }
        .frame(height: 260)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                arrowDrop = 14
            }
        }
    }
}

// MARK: - Step 2: CATEGORIES (+ shop frequency)

private struct CategoriesStep: View {
    @ObservedObject var vm: OnboardingViewModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 2)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.lg) {
                VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.sm) {
                    Text("WHAT YOU BUY")
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(1.2)
                        .foregroundStyle(Color.smoke)
                    Text("What do you buy most?")
                        .font(.shrunkLargeTitle)
                        .foregroundStyle(Color.ink)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("We'll watch these categories and send you the weekly digest.")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.smoke)
                        .lineSpacing(2)
                }
                .padding(.top, ShrunkTheme.Spacing.sm)

                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(GroceryCategory.allCases) { category in
                        CategoryToggle(
                            category: category,
                            isSelected: vm.profile.categories.contains(category)
                        ) {
                            vm.toggleCategory(category)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.sm) {
                    Text("How often do you shop?")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.ink)
                    Picker("How often do you shop?", selection: Binding(
                        get: { vm.profile.shopFrequency },
                        set: { vm.selectFrequency($0) }
                    )) {
                        ForEach(ShopFrequency.allCases) { frequency in
                            Text(frequency.shortLabel).tag(frequency)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("Sets how many times a year we count each shrink against you.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.smokeSoft)
                }
                .padding(.top, ShrunkTheme.Spacing.sm)
            }
            .padding(.horizontal, ShrunkTheme.Spacing.lg)
            .padding(.bottom, ShrunkTheme.Spacing.lg)
        }
        .scrollIndicators(.hidden)
    }
}

private struct CategoryToggle: View {
    let category: GroceryCategory
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? Color.shrunkRed : Color.shrunkRedLight)
                        .frame(width: 50, height: 50)
                    Image(systemName: category.icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : Color.shrunkRed)
                }
                Text(category.label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ink)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(isSelected ? Color.shrunkRedLight : Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous)
                    .stroke(isSelected ? Color.shrunkRed : Color.borderSoft,
                            lineWidth: isSelected ? 2 : 0.5)
            )
            .shrunkElevation(isSelected ? ShrunkTheme.Elevation.card : ShrunkTheme.Elevation.whisper)
            .scaleEffect(isSelected ? 1.02 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.78), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

#Preview {
    OnboardingContainerView { }
        .environmentObject(StoreKitService.shared)
}
