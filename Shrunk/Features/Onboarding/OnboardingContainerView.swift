import SwiftUI

struct OnboardingContainerView: View {
    @StateObject private var vm = OnboardingViewModel()
    @EnvironmentObject private var storeKit: StoreKitService

    @AppStorage("shrunk.onboarding_profile") private var persistedProfile: String = "{}"

    let onFinish: () -> Void

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                progressBar
                pageContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ctaSection
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
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
                Label("SHRUNK", systemImage: "barcode.viewfinder")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.shrunkRed)
            } else {
                Button {
                    vm.back()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline)
                }
                .accessibilityLabel("Back")
            }
            Spacer()
            if vm.step.allowsSkip {
                Button("Skip") { vm.skipStore() }
                    .font(.body)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    @ViewBuilder
    private var progressBar: some View {
        if vm.step.showsProgress {
            ProgressView(value: vm.progressFraction)
                .progressViewStyle(.linear)
                .animation(.easeOut(duration: 0.3), value: vm.progressFraction)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .accessibilityLabel("Setup progress")
        } else {
            Color.clear.frame(height: 4 + 16)
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
            .disabled(!vm.canAdvance)
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
        VStack(spacing: 32) {
            Spacer(minLength: 16)
            illustration
                .frame(maxWidth: .infinity)
            VStack(spacing: 12) {
                Text("They're shrinking your groceries.")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text("Same price. Less product. Scan a barcode and see exactly what changed.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            .padding(.horizontal, 20)
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
                .fill(Color(.secondarySystemGroupedBackground))
                .frame(width: 156, height: 196)
                .rotationEffect(.degrees(-6))
                .offset(x: -22, y: 6)
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .frame(width: 156, height: 196)
                .overlay(
                    VStack(alignment: .leading, spacing: 8) {
                        Capsule().fill(Color(.tertiarySystemFill)).frame(width: 80, height: 8)
                        Capsule().fill(Color(.tertiarySystemFill)).frame(width: 110, height: 8)
                        Capsule().fill(Color(.tertiarySystemFill)).frame(width: 60, height: 8)
                        Spacer()
                        Capsule()
                            .fill(Color.shrunkRedLight)
                            .frame(width: 90, height: 24)
                            .overlay(
                                Text("$1.89")
                                    .font(.footnote.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(Color.shrunkRedDark)
                            )
                    }
                    .padding(16)
                )
                .rotationEffect(.degrees(4))
                .offset(x: 18, y: -2)
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
            ZStack {
                Circle()
                    .fill(Color.shrunkRed)
                    .frame(width: 78, height: 78)
                Image(systemName: "arrow.down")
                    .font(.system(size: 32, weight: .bold))
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
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What do you buy most?")
                        .font(.largeTitle.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    Text("We'll watch these categories and send you the weekly digest.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)

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

                VStack(alignment: .leading, spacing: 8) {
                    Text("How often do you shop?")
                        .font(.headline)
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
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
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
                Image(systemName: category.icon)
                    .font(.title)
                    .foregroundStyle(Color.shrunkRed)
                    .frame(height: 36)
                Text(category.label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color(.label))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.shrunkRed : Color.clear, lineWidth: 2)
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.shrunkRed)
                        .padding(8)
                }
            }
            .animation(.easeOut(duration: 0.2), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

#Preview {
    OnboardingContainerView { }
        .environmentObject(StoreKitService.shared)
}
