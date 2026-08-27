import Foundation
import SwiftUI

@MainActor
final class OnboardingViewModel: ObservableObject {
    /// Spec §7: welcome → pick categories → set store (skippable) → paywall.
    enum Step: Int, CaseIterable, Identifiable {
        case welcome    = 0
        case categories
        case store
        case paywall

        var id: Int { rawValue }

        var showsProgress: Bool { self != .welcome }

        /// Only the store step can be skipped; the paywall owns its own exit.
        var allowsSkip: Bool { self == .store }
    }

    @Published var step: Step = .welcome
    @Published var profile: OnboardingProfile = .empty

    /// The CTA is enabled only when the step's required data is captured.
    var canAdvance: Bool {
        switch step {
        case .categories: return !profile.categories.isEmpty
        default:          return true
        }
    }

    var progressFraction: Double {
        Double(step.rawValue) / Double(Step.allCases.count - 1)
    }

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        withAnimation(.easeInOut(duration: 0.32)) { step = next }
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        withAnimation(.easeInOut(duration: 0.32)) { step = previous }
    }

    /// "I'll do this later" on the store step — a store is optional everywhere
    /// in the app (spec §8: loss of Kroger degrades, never breaks).
    func skipStore() {
        withAnimation(.easeInOut(duration: 0.32)) { step = .paywall }
    }

    func toggleCategory(_ category: GroceryCategory) {
        if profile.categories.contains(category) {
            profile.categories.remove(category)
        } else {
            profile.categories.insert(category)
        }
    }

    func selectFrequency(_ frequency: ShopFrequency) {
        profile.shopFrequency = frequency
    }
}
