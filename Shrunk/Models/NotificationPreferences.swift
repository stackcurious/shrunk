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

    static let `default` = NotificationPreferences(
        paused: false,
        quietHoursEnabled: false,
        quietHoursStartHour: 22,
        quietHoursEndHour: 8,
        minimumShrinkPercent: 0.03   // ignore anything under 3% — likely noise
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
