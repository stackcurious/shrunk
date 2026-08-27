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

extension DeviceIdentity {
    /// Alias for Phase 5's naming; both refer to the one persisted install id.
    static var storageKey: String { key }

    /// `current` as a `UUID` — what StoreKit's `appAccountToken` requires.
    /// `current` is always minted as `UUID().uuidString` (Phase 2), so the
    /// fallback below never fires in practice; if it ever did, it re-mints
    /// and persists a fresh UUID under the same key so `current` and
    /// `currentUUID` can never diverge. The fresh value is written through
    /// `stored` — the same `@AppStorage` setter `current` uses — rather than
    /// a raw `UserDefaults.standard.set`, so a later `current` read sees the
    /// same value `currentUUID` just minted instead of a stale legacy string.
    static var currentUUID: UUID {
        if let uuid = UUID(uuidString: current) { return uuid }
        let fresh = UUID()
        stored = fresh.uuidString
        return fresh
    }
}

#if DEBUG
extension DeviceIdentity {
    /// Test-only seam: writes through the same `stored` `@AppStorage` setter
    /// `current`/`currentUUID` use, so a seeded value is reliably observed
    /// within this process — unlike a bare `UserDefaults.standard.set`, which
    /// the static `@AppStorage` wrapper doesn't consistently pick up mid-process
    /// (see the precedent note on `ShrunkAPIClientTests.test_deviceIdentity_mintsOnceAndSticks`).
    static func _resetForTesting(to value: String) {
        stored = value
    }
}
#endif
