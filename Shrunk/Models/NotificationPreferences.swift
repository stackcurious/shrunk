import Foundation

/// User-controllable filters on top of iOS-level notification authorization.
/// Persisted to UserDefaults as JSON; read by `NotificationScheduler` before
/// delivering a watchlist alert.
struct NotificationPreferences: Codable, Equatable {
    var paused: Bool
    var quietHoursEnabled: Bool
    var quietHoursStartHour: Int   // 0..23
    var quietHoursEndHour: Int     // 0..23
    var minimumShrinkPercent: Double  // 0...1, threshold below which we don't fire

    // Per-kind switches for the server-sent alerts (spec §3, §6.2).
    var sizeDropEnabled: Bool = true
    var priceHikeEnabled: Bool = true
    var verifiedCaseEnabled: Bool = true
    var digestEnabled: Bool = true

    static let `default` = NotificationPreferences(
        paused: false,
        quietHoursEnabled: false,
        quietHoursStartHour: 22,
        quietHoursEndHour: 8,
        minimumShrinkPercent: 0.03,   // ignore anything under 3% — likely noise
        sizeDropEnabled: true,
        priceHikeEnabled: true,
        verifiedCaseEnabled: true,
        digestEnabled: true
    )

    // MARK: - JSON helpers for @AppStorage (UserDefaults stores String)

    func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    static func decoded(_ raw: String) -> NotificationPreferences {
        guard let data = raw.data(using: .utf8),
              let prefs = try? JSONDecoder().decode(NotificationPreferences.self, from: data)
        else { return .default }
        return prefs
    }

    // MARK: - Evaluation

    /// Returns true if an alert with the given shrink percent should fire NOW,
    /// given these preferences and the current wall-clock time.
    func shouldFire(shrinkPercent: Double, at date: Date = Date()) -> Bool {
        if paused { return false }
        if abs(shrinkPercent) < minimumShrinkPercent { return false }
        if quietHoursEnabled, isInQuietHours(date) { return false }
        return true
    }

    func isInQuietHours(_ date: Date) -> Bool {
        let hour = Calendar.current.component(.hour, from: date)
        if quietHoursStartHour == quietHoursEndHour { return false }
        if quietHoursStartHour < quietHoursEndHour {
            // Same-day window, e.g. 9 → 17
            return hour >= quietHoursStartHour && hour < quietHoursEndHour
        } else {
            // Wraps midnight, e.g. 22 → 8
            return hour >= quietHoursStartHour || hour < quietHoursEndHour
        }
    }
}

extension NotificationPreferences {
    static let appStorageKey = "shrunk.notification_prefs"

    /// `HH:00` formatted label for a 24-hour hour value, e.g. `9` → `"9:00 AM"`.
    static func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        components.minute = 0
        let date = Calendar.current.date(from: components) ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}

extension NotificationPreferences {
    /// Hand-written so preferences saved by an earlier build — which have none
    /// of the per-kind keys — still decode, with every kind on.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paused = try container.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        quietHoursEnabled = try container.decodeIfPresent(Bool.self, forKey: .quietHoursEnabled) ?? false
        quietHoursStartHour = try container.decodeIfPresent(Int.self, forKey: .quietHoursStartHour) ?? 22
        quietHoursEndHour = try container.decodeIfPresent(Int.self, forKey: .quietHoursEndHour) ?? 8
        minimumShrinkPercent = try container.decodeIfPresent(Double.self, forKey: .minimumShrinkPercent) ?? 0.03
        sizeDropEnabled = try container.decodeIfPresent(Bool.self, forKey: .sizeDropEnabled) ?? true
        priceHikeEnabled = try container.decodeIfPresent(Bool.self, forKey: .priceHikeEnabled) ?? true
        verifiedCaseEnabled = try container.decodeIfPresent(Bool.self, forKey: .verifiedCaseEnabled) ?? true
        digestEnabled = try container.decodeIfPresent(Bool.self, forKey: .digestEnabled) ?? true
    }

    /// The `prefs` object `POST /v1/devices` stores, keyed by the Worker's wire
    /// kind names. "Pause all alerts" switches every server push off too.
    var kindTogglePayload: [String: Bool] {
        [
            "sizeDrop": sizeDropEnabled && !paused,
            "priceHike": priceHikeEnabled && !paused,
            "verifiedCase": verifiedCaseEnabled && !paused,
            "digest": digestEnabled && !paused,
        ]
    }
}
