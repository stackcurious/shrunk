import SwiftUI
import Security

/// Stable per-install identifier. Crowd submissions carry it so a reviewer can
/// see repeat contributors, and Phase 4's `/v1/devices` sync reuses it.
///
/// Backed by the Keychain (survives a binary uninstall + reinstall — the
/// whole point of R42/C1, since a paid subscription's `appAccountToken` is
/// fixed at purchase and can't be re-baked). `UserDefaults` under the
/// `device_id` key is kept as a mirror only, so a SwiftUI view can still read
/// the same value with `@AppStorage("device_id")`.
///
/// Minted and normalized lowercase (ruling R42): the Worker's `appAccountToken`
/// comparison lowercases both sides, and every sender should be able to
/// compare `device_id` byte-for-byte without an extra normalization step.
enum DeviceIdentity {
    /// Exposed for tests; the literal below must stay in sync (a property-wrapper
    /// attribute cannot reference another static of the same type reliably).
    static let key = "device_id"

    @AppStorage("device_id") private static var stored: String = ""

    /// The store of record. `UserDefaults` (`stored`, above) is kept as a
    /// mirror only, so existing `@AppStorage("device_id")` readers keep
    /// working — the Keychain entry is what actually survives a reinstall.
    private static var store: DeviceIdentityStore = KeychainDeviceIdentityStore()

    static var current: String {
        if let existing = store.read(), !existing.isEmpty {
            // The Keychain value is authoritative. Normalize to lowercase and
            // keep the UserDefaults mirror in sync — this is what makes a
            // reinstall (Keychain present, UserDefaults wiped by the OS)
            // transparently recover the same id.
            let normalized = existing.lowercased()
            if stored != normalized { stored = normalized }
            return normalized
        }
        if !stored.isEmpty {
            // Pre-Keychain install: migrate the legacy UserDefaults value
            // into the Keychain on first read, lowercasing it in the
            // process so every sender agrees on casing going forward.
            let normalized = stored.lowercased()
            store.write(normalized)
            stored = normalized
            return normalized
        }
        let fresh = UUID().uuidString.lowercased()
        store.write(fresh)
        stored = fresh
        return fresh
    }
}

extension DeviceIdentity {
    /// Alias for Phase 5's naming; both refer to the one persisted install id.
    static var storageKey: String { key }

    /// `current` as a `UUID` — what StoreKit's `appAccountToken` requires.
    /// `current` is always minted as `UUID().uuidString.lowercased()`
    /// (Phase 2 / R42), so the fallback below never fires in practice; if it
    /// ever did, it re-mints and persists a fresh UUID under the same key so
    /// `current` and `currentUUID` can never diverge. The fresh value is
    /// written through both stores — the same paths `current` uses — rather
    /// than a raw `UserDefaults.standard.set`, so a later `current` read sees
    /// the same value `currentUUID` just minted instead of a stale legacy
    /// string. `UUID.uuidString` itself always renders uppercase (Foundation
    /// formats from the stored bytes, not from how the string was parsed),
    /// which is fine: `.appAccountToken(_:)` takes a `UUID`, not a string,
    /// and Apple's JWS canonicalizes `appAccountToken` to lowercase
    /// regardless. Anything that sends `device_id` as a *string* must use
    /// `current`, not `currentUUID.uuidString`.
    static var currentUUID: UUID {
        if let uuid = UUID(uuidString: current) { return uuid }
        let fresh = UUID()
        let value = fresh.uuidString.lowercased()
        store.write(value)
        stored = value
        return fresh
    }
}

/// Abstraction over the Keychain-backed store so tests can substitute an
/// isolated in-memory double instead of touching the real Keychain.
protocol DeviceIdentityStore {
    func read() -> String?
    func write(_ value: String)
}

/// Reads/writes the Keychain-backed device id. A generic-password item under
/// a dedicated service/account, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// so the item stays available in the background but never leaves the device
/// via iCloud Keychain sync, and — this is the whole point of C1 — survives a
/// binary uninstall + reinstall, unlike `UserDefaults`.
struct KeychainDeviceIdentityStore: DeviceIdentityStore {
    private let service = "com.shrunk.device"
    private let account = "device_id"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String) {
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery.merge(attributes) { _, new in new }
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }
}

#if DEBUG
/// Test-only double for `DeviceIdentityStore`. Exposed (not `private`) so a
/// test can seed or inspect `value` directly, independent of the
/// UserDefaults mirror `DeviceIdentity` also maintains.
final class InMemoryDeviceIdentityStore: DeviceIdentityStore {
    var value: String?
    func read() -> String? { value }
    func write(_ value: String) { self.value = value }
}

extension DeviceIdentity {
    /// Test-only seam: writes through the same `stored` `@AppStorage` setter
    /// and the backing `store` `current`/`currentUUID` use, so a seeded value
    /// is reliably observed within this process — unlike a bare
    /// `UserDefaults.standard.set`, which the static `@AppStorage` wrapper
    /// doesn't consistently pick up mid-process (see the precedent note on
    /// `ShrunkAPIClientTests.test_deviceIdentity_mintsOnceAndSticks`). Resets
    /// BOTH stores so nothing about a prior test can leak into `current`.
    static func _resetForTesting(to value: String) {
        stored = value
        store.write(value)
    }

    /// Test-only seam: swaps in an isolated in-memory store so
    /// `DeviceIdentityTests` never touches the real Keychain, and returns
    /// the double so a test can seed/inspect it directly, independent of the
    /// UserDefaults mirror. (The simulator Keychain does work fine under
    /// XCTest — this is just extra isolation, and it also guarantees a fresh,
    /// empty store rather than whatever a previous test left behind.)
    @discardableResult
    static func _useInMemoryStoreForTesting() -> InMemoryDeviceIdentityStore {
        let double = InMemoryDeviceIdentityStore()
        store = double
        return double
    }

    /// Seeds only the UserDefaults mirror, leaving the backing store
    /// untouched — the exact shape of an install from before Keychain
    /// backing landed. Used to test the first-read migration path.
    static func _seedUserDefaultsOnlyForTesting(_ value: String) {
        stored = value
    }
}
#endif
