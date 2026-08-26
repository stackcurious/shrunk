import SwiftUI

/// Stable per-install identifier. Crowd submissions carry it so a reviewer can
/// see repeat contributors, and Phase 4's `/v1/devices` sync reuses it.
///
/// Stored under the `device_id` key, so a SwiftUI view can read the same value
/// with `@AppStorage("device_id")`.
enum DeviceIdentity {
    /// Exposed for tests; the literal below must stay in sync (a property-wrapper
    /// attribute cannot reference another static of the same type reliably).
    static let key = "device_id"

    @AppStorage("device_id") private static var stored: String = ""

    static var current: String {
        if !stored.isEmpty { return stored }
        let fresh = UUID().uuidString
        stored = fresh
        return fresh
    }
}
