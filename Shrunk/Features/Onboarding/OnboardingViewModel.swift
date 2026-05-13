import Foundation
import SwiftUI

@MainActor
final class OnboardingViewModel: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case hero       = 0   // brand hook
        case problem        // frame the enemy
        case household      // Q1
        case frequency      // Q2
        case categories     // Q3 multi-select
        case spend          // Q4 slider
        case socialProof    // trust + authority
        case analyzing      // labor illusion
        case reveal         // personalized $/yr
        case paywall        // $9.99 lifetime

        var id: Int { rawValue }

        /// Steps that show the chrome progress bar at the top.
        var showsProgress: Bool {
            switch self {
            case .hero, .analyzing, .paywall: return false
            default: return true
            }
        }

        /// Steps where the user can skip the rest of onboarding.
        /// Cal AI only allows skip on early commitment screens, never on paywall.
        var allowsSkip: Bool {
            switch self {
            case .hero, .problem: return true
            default: return false
            }
        }
    }

    @Published var step: Step = .hero
    @Published var profile: OnboardingProfile = .empty
    @Published var analyzeProgress: Double = 0
    @Published var analyzeMessage: String = "Loading…"

    private var analyzeTask: Task<Void, Never>?

    /// CTA is enabled only when the current step's required data is captured.
    var canAdvance: Bool {
        switch step {
        case .hero, .problem, .socialProof, .reveal, .paywall:
            return true
        case .household:   return profile.householdSize != nil
        case .frequency:   return profile.shopFrequency != nil
        case .categories:  return !profile.categories.isEmpty
        case .spend:       return profile.monthlySpend != nil
        case .analyzing:   return false   // auto-advances
        }
    }

    var progressFraction: Double {
        let total = Double(Step.allCases.count - 1)
        return Double(step.rawValue) / total
    }

    /// Forecast computed from current profile. Used live on the spend step
    /// (for the "$X/yr at risk" hint that updates as the slider moves) and on
    /// the reveal screen.
    var forecast: SavingsForecast {
        SavingsForecast.compute(profile: profile)
    }

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        withAnimation(.easeInOut(duration: 0.32)) {
            step = next
        }
        if next == .analyzing {
            startAnalyzing()
        }
    }

    func back() {
        guard let prev = Step(rawValue: step.rawValue - 1) else { return }
        withAnimation(.easeInOut(duration: 0.32)) {
            step = prev
        }
    }

    func skipToReveal() {
        // Soft-skip used by Cal AI on the early screens: jump to the reveal so
        // the user still sees the hook even if they bailed on the quiz.
        withAnimation(.easeInOut(duration: 0.32)) {
            step = .reveal
        }
    }

    func selectHousehold(_ size: HouseholdSize) {
        profile.householdSize = size
    }

    func selectFrequency(_ freq: ShopFrequency) {
        profile.shopFrequency = freq
    }

    func toggleCategory(_ cat: GroceryCategory) {
        if profile.categories.contains(cat) {
            profile.categories.remove(cat)
        } else {
            profile.categories.insert(cat)
        }
    }

    func setSpend(_ amount: Double) {
        profile.monthlySpend = amount
    }

    // MARK: - Analyzing animation
    //
    // 3-stage rotating status string + a smooth 3.2s progress fill. The labor-
    // illusion screens that work best linger long enough for the user to *read*
    // the messages — Cal AI's analyzing screen runs ~4s. We use 3.2s so the
    // flow feels snappy without sacrificing the perception of work.

    private func startAnalyzing() {
        analyzeTask?.cancel()
        analyzeProgress = 0
        analyzeMessage = "Pulling product price histories…"
        analyzeTask = Task { @MainActor in
            let messages: [(Double, String)] = [
                (0.30, "Pulling product price histories…"),
                (0.65, "Checking shrinkflation rates for your categories…"),
                (1.00, "Calculating your exposure…")
            ]

            let totalSteps = 64
            let stepInterval = UInt64(50_000_000)   // 50ms × 64 ≈ 3.2s
            for i in 1...totalSteps {
                if Task.isCancelled { return }
                let p = Double(i) / Double(totalSteps)
                if let next = messages.first(where: { p <= $0.0 }) {
                    analyzeMessage = next.1
                }
                withAnimation(.linear(duration: 0.05)) {
                    analyzeProgress = p
                }
                try? await Task.sleep(nanoseconds: stepInterval)
            }
            // Brief pause at 100% before reveal so the user sees it complete.
            try? await Task.sleep(nanoseconds: 350_000_000)
            advance()
        }
    }

    deinit {
        analyzeTask?.cancel()
    }
}
