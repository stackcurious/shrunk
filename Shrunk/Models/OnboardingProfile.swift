import Foundation

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

    var shortLabel: String {
        switch self {
        case .weekly:    return "Weekly"
        case .biweekly:  return "Every 2 wks"
        case .monthly:   return "Monthly"
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

/// The categories a user picks in onboarding. Synced to `/v1/devices` so the
/// weekly digest can be filtered (spec §6.2).
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
}

/// Persisted via @AppStorage as JSON. Two fields, both of which drive real
/// behaviour: `categories` filters the digest, `shopFrequency` is the
/// purchases-per-year multiplier in the savings dashboard (spec §3.5).
struct OnboardingProfile: Codable, Equatable {
    var categories: Set<GroceryCategory> = []
    var shopFrequency: ShopFrequency = .biweekly

    static let empty = OnboardingProfile()

    /// Custom decoding so profiles written before this phase — which carry
    /// `householdSize` and `monthlySpend`, and may omit `shopFrequency` —
    /// still decode instead of resetting the user.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        categories = try container.decodeIfPresent(Set<GroceryCategory>.self, forKey: .categories) ?? []
        shopFrequency = try container.decodeIfPresent(ShopFrequency.self, forKey: .shopFrequency) ?? .biweekly
    }

    init(categories: Set<GroceryCategory> = [], shopFrequency: ShopFrequency = .biweekly) {
        self.categories = categories
        self.shopFrequency = shopFrequency
    }
}

extension OnboardingProfile {
    /// JSON round-trip helpers for @AppStorage (UserDefaults stores String).
    func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    static func decoded(_ raw: String) -> OnboardingProfile {
        guard let data = raw.data(using: .utf8),
              let profile = try? JSONDecoder().decode(OnboardingProfile.self, from: data)
        else { return .empty }
        return profile
    }
}
