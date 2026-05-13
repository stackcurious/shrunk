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
            if isPro { finish() }
        }
    }

    private func finish() {
        persistedProfile = vm.profile.encoded()
        onFinish()
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            if vm.step != .hero && vm.step != .analyzing {
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
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "barcode.viewfinder")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.shrunkRed)
                    Text("SHRUNK")
                        .font(.system(size: 13, weight: .heavy))
                        .tracking(1.6)
                        .foregroundStyle(Color.ink)
                }
            }
            Spacer()
            if vm.step.allowsSkip {
                Button("Skip") { vm.skipToReveal() }
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
        case .hero:         HeroStep()
        case .problem:      ProblemStep()
        case .household:    HouseholdStep(vm: vm)
        case .frequency:    FrequencyStep(vm: vm)
        case .categories:   CategoriesStep(vm: vm)
        case .spend:        SpendStep(vm: vm)
        case .socialProof:  SocialProofStep()
        case .analyzing:    AnalyzingStep(vm: vm)
        case .reveal:       RevealStep(forecast: vm.forecast)
        case .paywall:      PaywallStep(forecast: vm.forecast,
                                       onPurchase: { await runPurchase() },
                                       onSkip:     { finish() })
        }
    }

    // MARK: - CTA

    @ViewBuilder
    private var ctaSection: some View {
        switch vm.step {
        case .analyzing:
            // No CTA during the labor-illusion animation.
            Color.clear.frame(height: 56)
        case .paywall:
            // PaywallStep owns its own CTAs (purchase + skip).
            Color.clear.frame(height: 0)
        default:
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
        case .hero:        return "Show me how"
        case .problem:     return "I want to catch this"
        case .household:   return "Continue"
        case .frequency:   return "Continue"
        case .categories:  return "Continue"
        case .spend:       return "Continue"
        case .socialProof: return "Run my analysis"
        case .reveal:      return "Stop the bleeding"
        default:           return "Continue"
        }
    }

    @MainActor
    private func runPurchase() async {
        do {
            try await storeKit.purchase()
        } catch {
            // Errors surface inside PaywallStep via storeKit.loadError.
        }
    }
}

// MARK: - Step 1: HERO

private struct HeroStep: View {
    @State private var arrowDrop: CGFloat = -10

    var body: some View {
        StepLayout(
            illustration: {
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
                        .rotationEffect(.degrees(4))
                        .offset(x: 18, y: -2)
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
            },
            headline: "They're shrinking your groceries.",
            subhead: "Same price. Less product. Most people never notice."
        )
    }
}

// MARK: - Step 2: PROBLEM

private struct ProblemStep: View {
    var body: some View {
        ScrollView {
            VStack(spacing: ShrunkTheme.Spacing.lg) {
                VStack(spacing: ShrunkTheme.Spacing.sm) {
                    Text("In the last 5 years…")
                        .font(.system(size: 13, weight: .heavy))
                        .tracking(0.8)
                        .foregroundStyle(Color.smoke)
                    Text("Brands quietly shrunk packages **5–18%** — same shelf, same price.")
                        .font(.shrunkLargeTitle)
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .padding(.horizontal, ShrunkTheme.Spacing.md)
                }

                VStack(spacing: 10) {
                    receiptCard(brand: "Gatorade", from: "32 fl oz", to: "28 fl oz", percent: "-12.5%")
                    receiptCard(brand: "Doritos",  from: "9.75 oz",  to: "9.25 oz", percent: "-5.1%")
                    receiptCard(brand: "Folgers",  from: "51 oz",    to: "43.5 oz", percent: "-14.7%")
                }
                .padding(.horizontal, ShrunkTheme.Spacing.lg)
            }
            .padding(.top, ShrunkTheme.Spacing.md)
            .padding(.bottom, ShrunkTheme.Spacing.lg)
        }
        .scrollIndicators(.hidden)
    }

    private func receiptCard(brand: String, from: String, to: String, percent: String) -> some View {
        HStack(spacing: ShrunkTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(brand)
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(Color.ink)
                Text("\(from) → \(to)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.smoke)
            }
            Spacer()
            Text(percent)
                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                .foregroundStyle(Color.shrunkRedDark)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.shrunkRedLight)
                .clipShape(Capsule())
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
}

// MARK: - Step 3: HOUSEHOLD

private struct HouseholdStep: View {
    @ObservedObject var vm: OnboardingViewModel

    var body: some View {
        QuestionLayout(
            eyebrow: "Question 1 of 4",
            question: "How many people in your household?",
            helper: "Helps us tailor your savings forecast."
        ) {
            VStack(spacing: 10) {
                ForEach(HouseholdSize.allCases) { size in
                    OptionRow(
                        icon: size.icon,
                        label: size.label,
                        isSelected: vm.profile.householdSize == size
                    ) {
                        vm.selectHousehold(size)
                    }
                }
            }
        }
    }
}

// MARK: - Step 4: FREQUENCY

private struct FrequencyStep: View {
    @ObservedObject var vm: OnboardingViewModel

    var body: some View {
        QuestionLayout(
            eyebrow: "Question 2 of 4",
            question: "How often do you grocery shop?",
            helper: nil
        ) {
            VStack(spacing: 10) {
                ForEach(ShopFrequency.allCases) { freq in
                    OptionRow(
                        icon: freq.icon,
                        label: freq.label,
                        isSelected: vm.profile.shopFrequency == freq
                    ) {
                        vm.selectFrequency(freq)
                    }
                }
            }
        }
    }
}

// MARK: - Step 5: CATEGORIES

private struct CategoriesStep: View {
    @ObservedObject var vm: OnboardingViewModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 2)

    var body: some View {
        QuestionLayout(
            eyebrow: "Question 3 of 4",
            question: "What do you buy most?",
            helper: "Pick everything that applies."
        ) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(GroceryCategory.allCases) { cat in
                    CategoryToggle(
                        category: cat,
                        isSelected: vm.profile.categories.contains(cat)
                    ) {
                        vm.toggleCategory(cat)
                    }
                }
            }
        }
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
    }
}

// MARK: - Step 6: SPEND

private struct SpendStep: View {
    @ObservedObject var vm: OnboardingViewModel
    @State private var localSpend: Double = OnboardingProfile.defaultSpend

    var body: some View {
        QuestionLayout(
            eyebrow: "Question 4 of 4",
            question: "About how much do you spend per month?",
            helper: "Don't worry about being exact."
        ) {
            VStack(spacing: ShrunkTheme.Spacing.lg) {
                VStack(spacing: 4) {
                    Text(currencyString(localSpend))
                        .font(.system(size: 56, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.ink)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: localSpend)
                    Text("per month on groceries")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.smoke)
                }
                .padding(.top, ShrunkTheme.Spacing.md)

                VStack(spacing: 6) {
                    Slider(
                        value: $localSpend,
                        in: OnboardingProfile.minSpend...OnboardingProfile.maxSpend,
                        step: 25
                    )
                    .tint(Color.shrunkRed)

                    HStack {
                        Text(currencyString(OnboardingProfile.minSpend))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.smokeSoft)
                        Spacer()
                        Text(currencyString(OnboardingProfile.maxSpend))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.smokeSoft)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .onAppear {
            // Initialize the slider from whatever was previously chosen, or the default.
            localSpend = vm.profile.monthlySpend ?? OnboardingProfile.defaultSpend
            vm.setSpend(localSpend)
        }
        .onChange(of: localSpend) { _, newValue in
            vm.setSpend(newValue)
        }
    }

    private func currencyString(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 0
        formatter.locale = .current
        return formatter.string(from: NSNumber(value: value)) ?? "$0"
    }
}

// MARK: - Step 7: SOCIAL PROOF

private struct SocialProofStep: View {
    var body: some View {
        ScrollView {
            VStack(spacing: ShrunkTheme.Spacing.lg) {
                ZStack {
                    Circle()
                        .fill(LinearGradient.verdictGoodDiagonal)
                        .frame(width: 120, height: 120)
                        .shrunkElevation(ShrunkTheme.Elevation.float)
                    Image(systemName: "shield.checkered")
                        .font(.system(size: 50, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.top, ShrunkTheme.Spacing.lg)

                VStack(spacing: 8) {
                    Text("Independent. On your side.")
                        .font(.shrunkLargeTitle)
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.center)
                    Text("Our data comes from Open Food Facts — a nonprofit, community-maintained database. No brand pays us. Ever.")
                        .font(.shrunkBody)
                        .foregroundStyle(Color.smoke)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, ShrunkTheme.Spacing.lg)
                        .lineSpacing(3)
                }

                VStack(spacing: 10) {
                    proofRow(icon: "leaf.fill", color: .verdictGood,
                             title: "Backed by Open Food Facts",
                             subtitle: "Nonprofit · 3M+ products")
                    proofRow(icon: "person.2.fill", color: .shrunkRed,
                             title: "Community-driven catalog",
                             subtitle: "Every shrink is logged, sourced, and timestamped")
                    proofRow(icon: "lock.shield.fill", color: .verdictWarn,
                             title: "No ads, no tracking, no sponsors",
                             subtitle: "Just you and the math")
                }
                .padding(.horizontal, ShrunkTheme.Spacing.lg)
            }
            .padding(.bottom, ShrunkTheme.Spacing.lg)
        }
        .scrollIndicators(.hidden)
    }

    private func proofRow(icon: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: ShrunkTheme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color.opacity(0.14))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text(subtitle)
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
                .stroke(Color.borderSoft, lineWidth: 0.5)
        )
        .shrunkElevation(ShrunkTheme.Elevation.whisper)
    }
}

// MARK: - Step 8: ANALYZING (labor illusion)

private struct AnalyzingStep: View {
    @ObservedObject var vm: OnboardingViewModel

    var body: some View {
        VStack(spacing: ShrunkTheme.Spacing.xl) {
            Spacer()

            // Spinning halo around a brand-colored ring
            ZStack {
                Circle()
                    .stroke(Color.shrunkRedLight, lineWidth: 14)
                    .frame(width: 180, height: 180)
                Circle()
                    .trim(from: 0, to: 0.32)
                    .stroke(LinearGradient.shrunkRedDiagonal,
                            style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .frame(width: 180, height: 180)
                    .rotationEffect(.degrees(spin))
                    .onAppear {
                        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                            spin = 360
                        }
                    }
                Text(percent)
                    .font(.system(size: 32, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Color.ink)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: vm.analyzeProgress)
            }

            VStack(spacing: 6) {
                Text(vm.analyzeMessage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                    .animation(.easeInOut(duration: 0.2), value: vm.analyzeMessage)
                Text("This takes a few seconds — don't close the app.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.smokeSoft)
            }

            // Progress bar reinforcement
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.border).frame(height: 6)
                    Capsule()
                        .fill(LinearGradient.shrunkRedDiagonal)
                        .frame(width: geo.size.width * vm.analyzeProgress, height: 6)
                }
            }
            .frame(height: 6)
            .padding(.horizontal, ShrunkTheme.Spacing.lg)

            Spacer()
        }
    }

    @State private var spin: Double = 0

    private var percent: String {
        "\(Int(vm.analyzeProgress * 100))%"
    }
}

// MARK: - Step 9: REVEAL

private struct RevealStep: View {
    let forecast: SavingsForecast

    @State private var counterValue: Double = 0
    @State private var bloomScale: CGFloat = 0.7

    var body: some View {
        ScrollView {
            VStack(spacing: ShrunkTheme.Spacing.lg) {
                VStack(spacing: 4) {
                    Text("BASED ON YOUR ANSWERS")
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(1.2)
                        .foregroundStyle(Color.smoke)
                    Text("You're losing about")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.smoke)
                }
                .padding(.top, ShrunkTheme.Spacing.md)

                Text(currencyString(counterValue))
                    .font(.system(size: 76, weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient.shrunkRedDiagonal)
                    .scaleEffect(bloomScale)
                    .contentTransition(.numericText())
                    .onAppear {
                        withAnimation(.spring(response: 0.55, dampingFraction: 0.7)) {
                            bloomScale = 1.0
                        }
                        // Count up from 0 to the actual total over 1.2s
                        withAnimation(.easeOut(duration: 1.2)) {
                            counterValue = forecast.totalAnnual
                        }
                    }

                Text("per year to shrinkflation")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.ink)

                VStack(spacing: 10) {
                    HStack {
                        Text("WHERE IT GOES")
                            .font(.system(size: 11, weight: .heavy))
                            .tracking(0.8)
                            .foregroundStyle(Color.smoke)
                        Spacer()
                    }
                    VStack(spacing: 6) {
                        let top5 = Array(forecast.perCategory.prefix(5))
                        ForEach(top5) { slice in
                            CategoryBar(slice: slice, max: top5.first?.annualLoss ?? 1)
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
                .shrunkElevation(ShrunkTheme.Elevation.card)
                .padding(.horizontal, ShrunkTheme.Spacing.lg)
                .padding(.top, ShrunkTheme.Spacing.sm)

                Text("We can catch this for you.")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .padding(.top, ShrunkTheme.Spacing.sm)
            }
            .padding(.bottom, ShrunkTheme.Spacing.lg)
        }
        .scrollIndicators(.hidden)
    }

    private func currencyString(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 0
        formatter.locale = .current
        return formatter.string(from: NSNumber(value: value)) ?? "$0"
    }
}

private struct CategoryBar: View {
    let slice: SavingsForecast.Slice
    let max: Double

    var body: some View {
        HStack(spacing: ShrunkTheme.Spacing.sm) {
            Image(systemName: slice.category.icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.shrunkRed)
                .frame(width: 18)
            Text(slice.category.label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.ink)
                .frame(width: 78, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.mist).frame(height: 8)
                    Capsule()
                        .fill(LinearGradient.shrunkRedDiagonal)
                        .frame(width: geo.size.width * (slice.annualLoss / (max == 0 ? 1 : max)), height: 8)
                }
            }
            .frame(height: 8)
            Text(currencyString(slice.annualLoss))
                .font(.system(size: 12, weight: .heavy, design: .monospaced))
                .foregroundStyle(Color.ink)
                .frame(width: 56, alignment: .trailing)
        }
    }

    private func currencyString(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 0
        formatter.locale = .current
        return formatter.string(from: NSNumber(value: value)) ?? "$0"
    }
}

// MARK: - Step 10: PAYWALL

private struct PaywallStep: View {
    @EnvironmentObject private var storeKit: StoreKitService
    let forecast: SavingsForecast
    let onPurchase: () async -> Void
    let onSkip: () -> Void

    @State private var purchaseInProgress: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: ShrunkTheme.Spacing.lg) {
                hero
                    .padding(.top, ShrunkTheme.Spacing.md)

                paybackChip
                    .padding(.horizontal, ShrunkTheme.Spacing.lg)

                valueProps
                    .padding(.horizontal, ShrunkTheme.Spacing.lg)

                VStack(spacing: 10) {
                    ShrunkButton(
                        "Unlock for \(storeKit.displayPrice)",
                        icon: "lock.open.fill",
                        isLoading: purchaseInProgress
                    ) {
                        Task {
                            purchaseInProgress = true
                            await onPurchase()
                            purchaseInProgress = false
                        }
                    }

                    Button("Continue with the free version") {
                        onSkip()
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.smoke)
                }
                .padding(.horizontal, ShrunkTheme.Spacing.lg)
                .padding(.top, ShrunkTheme.Spacing.sm)

                Text("One-time payment. No subscription. No auto-renew.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.smokeSoft)
                    .padding(.horizontal, ShrunkTheme.Spacing.lg)
                    .padding(.bottom, ShrunkTheme.Spacing.lg)
            }
        }
        .scrollIndicators(.hidden)
    }

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
                Text("Stop shrinkflation")
                    .font(.shrunkLargeTitle)
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                Text("Shrunk Pro · pay once, yours forever")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.smoke)
            }
        }
    }

    @ViewBuilder
    private var paybackChip: some View {
        if forecast.totalAnnual > 0 {
            HStack(spacing: ShrunkTheme.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(Color.verdictGoodTint)
                        .frame(width: 40, height: 40)
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.verdictGood)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Pays for itself in \(forecast.paybackDays) day\(forecast.paybackDays == 1 ? "" : "s")")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(Color.ink)
                    Text("vs. your \(forecast.totalDisplay)/yr exposure")
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
        }
    }

    private var valueProps: some View {
        VStack(spacing: 8) {
            propRow(icon: "bell.badge.fill",            color: .shrunkRed,    title: "Watch any product",  body: "We check daily and alert you the moment it shrinks.")
            propRow(icon: "list.bullet.rectangle.fill", color: .verdictGood,  title: "Every alternative",   body: "All ranked options — not just the top two.")
            propRow(icon: "shield.checkered",           color: .verdictWarn,  title: "Savings dashboard",   body: "Track exactly what you've protected.")
        }
    }

    private func propRow(icon: String, color: Color, title: String, body: String) -> some View {
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
}

// MARK: - Shared layouts

private struct StepLayout<Illustration: View>: View {
    @ViewBuilder let illustration: () -> Illustration
    let headline: String
    let subhead: String

    var body: some View {
        VStack(spacing: ShrunkTheme.Spacing.xl) {
            Spacer(minLength: ShrunkTheme.Spacing.md)
            illustration()
                .frame(maxWidth: .infinity)
            VStack(spacing: ShrunkTheme.Spacing.md) {
                Text(headline)
                    .font(.shrunkLargeTitle)
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                Text(subhead)
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
}

private struct QuestionLayout<Content: View>: View {
    let eyebrow: String
    let question: String
    let helper: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.lg) {
                VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.sm) {
                    Text(eyebrow.uppercased())
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(1.2)
                        .foregroundStyle(Color.smoke)
                    Text(question)
                        .font(.shrunkLargeTitle)
                        .foregroundStyle(Color.ink)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let helper {
                        Text(helper)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.smoke)
                            .lineSpacing(2)
                    }
                }
                .padding(.top, ShrunkTheme.Spacing.sm)

                content()
            }
            .padding(.horizontal, ShrunkTheme.Spacing.lg)
            .padding(.bottom, ShrunkTheme.Spacing.lg)
        }
        .scrollIndicators(.hidden)
    }
}

private struct OptionRow: View {
    let icon: String
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ShrunkTheme.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? Color.shrunkRed : Color.shrunkRedLight)
                        .frame(width: 42, height: 42)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : Color.shrunkRed)
                }
                Text(label)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.shrunkRed)
                }
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
    }
}

#Preview {
    OnboardingContainerView { }
        .environmentObject(StoreKitService.shared)
}
