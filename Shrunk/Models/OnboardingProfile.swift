import Foundation

enum HouseholdSize: String, Codable, CaseIterable, Identifiable {
    case one, two, threeFour, fivePlus

    var id: String { rawValue }

    var label: String {
        switch self {
        case .one:        return "Just me"
        case .two:        return "2 of us"
        case .threeFour:  return "3–4"
        case .fivePlus:   return "5 or more"
        }
    }

    var icon: String {
        switch self {
        case .one:        return "person.fill"
        case .two:        return "person.2.fill"
        case .threeFour:  return "person.3.fill"
        case .fivePlus:   return "person.3.sequence.fill"
        }
    }
}

enum ShopFrequency: String, Codable, CaseIterable, Identifiable {
    case weekly, biweekly, monthly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .weekly:    return "Every week"
        case .biweekly:  return "Every 2 weeks"
        case .monthly:   return "Once a month"
        }
    }

    var icon: String {
        switch self {
        case .weekly:    return "calendar"
        case .biweekly:  return "calendar.badge.clock"
        case .monthly:   return "calendar.circle"
        }
    }
}

/// The category set used for personalization. Mirrors `BrowseViewModel.BrowseCategory` in shape
/// but is kept decoupled — Browse needs OFF slugs, this needs basket weights for the savings math.
enum GroceryCategory: String, Codable, CaseIterable, Identifiable {
    case snacks, drinks, dairy, cleaning, personal, paper

    var id: String { rawValue }

    var label: String {
        switch self {
        case .snacks:    return "Snacks"
        case .drinks:    return "Drinks"
        case .dairy:     return "Dairy"
        case .cleaning:  return "Cleaning"
        case .personal:  return "Personal"
        case .paper:     return "Paper"
        }
    }

    var icon: String {
        switch self {
        case .snacks:    return "popcorn.fill"
        case .drinks:    return "cup.and.saucer.fill"
        case .dairy:     return "drop.fill"
        case .cleaning:  return "sparkles"
        case .personal:  return "drop.degreesign"
        case .paper:     return "rectangle.stack.fill"
        }
    }

    /// Share of a typical grocery basket this category occupies (USDA-ish averages).
    var basketShare: Double {
        switch self {
        case .snacks:    return 0.12
        case .drinks:    return 0.15
        case .dairy:     return 0.15
        case .cleaning:  return 0.05
        case .personal:  return 0.08
        case .paper:     return 0.05
        }
    }

    /// Average shrinkflation rate observed in this category over the past 5 years.
    /// Sourced from our curated catalog (Gatorade 12.5%, Doritos 5.1%, Folgers 14.7%, etc.)
    /// rounded to defensible category-level averages.
    var shrinkRate: Double {
        switch self {
        case .snacks:    return 0.090
        case .drinks:    return 0.120
        case .dairy:     return 0.060
        case .cleaning:  return 0.080
        case .personal:  return 0.075
        case .paper:     return 0.085
        }
    }
}

/// Persisted via @AppStorage as JSON (UserDefaults). Profile drives both
/// the onboarding reveal and any in-app savings dashboard later.
struct OnboardingProfile: Codable, Equatable {
    var householdSize: HouseholdSize?
    var shopFrequency: ShopFrequency?
    var categories: Set<GroceryCategory> = []
    var monthlySpend: Double?

    /// Spend defaulted when the user hasn't set a value yet (still on the slider screen).
    /// $500/mo is the US median grocery spend for a 2-person household.
    static let defaultSpend: Double = 500
    static let minSpend: Double = 150
    static let maxSpend: Double = 1500

    static let empty = OnboardingProfile()
}

extension OnboardingProfile {
    /// JSON round-trip helpers for @AppStorage (UserDefaults stores String).
    func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    static func decoded(_ raw: String) -> OnboardingProfile {
        guard let data = raw.data(using: .utf8),
              let profile = try? JSONDecoder().decode(OnboardingProfile.self, from: data)
        else { return .empty }
        return profile
    }
}
