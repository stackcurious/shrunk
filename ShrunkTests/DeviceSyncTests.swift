import XCTest
@testable import Shrunk

final class DeviceIdentityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Isolate from the real Keychain: the simulator Keychain does work
        // under XCTest, but a fresh in-memory double keeps this class
        // hermetic and guarantees no value leaks in from (or out to) another
        // test class sharing this process's `DeviceIdentity` static state.
        DeviceIdentity._useInMemoryStoreForTesting()
        // Clear through the wrapper's own setter, not a raw
        // `UserDefaults.standard.removeObject` — the static `@AppStorage`
        // cache doesn't reliably observe an external removal mid-process
        // (see the precedent note on
        // `ShrunkAPIClientTests.test_deviceIdentity_mintsOnceAndSticks`), so
        // a value a previous test wrote through the setter could otherwise
        // survive into this one despite the key being gone from disk.
        DeviceIdentity._resetForTesting(to: "")
    }

    override func tearDown() {
        // Same reasoning as `setUp`: reset through the setter so nothing
        // written via `_resetForTesting`/`current`/`currentUUID` in this test
        // can leak into the next test — in this class or another, since
        // `DeviceIdentity`'s backing statics are shared process-wide.
        DeviceIdentity._resetForTesting(to: "")
        DeviceIdentity._useInMemoryStoreForTesting()
        super.tearDown()
    }

    func test_storageKey_aliasesKey() {
        XCTAssertEqual(DeviceIdentity.storageKey, DeviceIdentity.key)
    }

    func test_currentUUID_isStableAcrossCalls() {
        let first = DeviceIdentity.currentUUID
        let second = DeviceIdentity.currentUUID
        XCTAssertEqual(first, second)
    }

    func test_currentUUID_matchesCurrentAsAUUID() {
        // Phase 2's `current` always mints UUID().uuidString, so the two never
        // diverge *as UUID values* — but R42 lowercases `current` while
        // `UUID.uuidString` always renders uppercase (it formats from the
        // stored bytes, not from how the string was parsed), so the string
        // comparison must fold case.
        XCTAssertEqual(DeviceIdentity.currentUUID.uuidString.lowercased(), DeviceIdentity.current)
    }

    func test_current_mintsLowercase() {
        let minted = DeviceIdentity.current
        XCTAssertEqual(minted, minted.lowercased(), "R42: the minted id must be lowercase")
        XCTAssertNotNil(UUID(uuidString: minted))
    }

    func test_current_mintsOnlyOnceWhenBothStoresAreEmpty() {
        let first = DeviceIdentity.current
        let second = DeviceIdentity.current
        XCTAssertEqual(first, second, "mint-once: a second read must not mint a new id")
    }

    func test_current_migratesLegacyUserDefaultsValueIntoTheStore() {
        let double = DeviceIdentity._useInMemoryStoreForTesting()
        DeviceIdentity._seedUserDefaultsOnlyForTesting("LEGACY-UPPER-VALUE")
        XCTAssertNil(double.value, "precondition: the backing store has nothing yet")

        let value = DeviceIdentity.current

        XCTAssertEqual(value, "legacy-upper-value", "R42: a migrated value is lowercased too")
        XCTAssertEqual(double.value, "legacy-upper-value",
                        "first read must migrate the UserDefaults value into the store")
    }

    func test_current_prefersTheStoreOverUserDefaultsSoAReinstallSurvives() {
        let double = DeviceIdentity._useInMemoryStoreForTesting()
        // Simulate a reinstall: UserDefaults is wiped by the OS (setUp already
        // cleared it), but the Keychain-backed store — the whole point of
        // C1 — survives and still holds the original id.
        double.value = "surviving-value"

        XCTAssertEqual(DeviceIdentity.current, "surviving-value")
    }

    func test_resetForTesting_setsBothStores() {
        let double = DeviceIdentity._useInMemoryStoreForTesting()
        DeviceIdentity._resetForTesting(to: "reset-value")

        XCTAssertEqual(double.value, "reset-value", "must reset the backing store")
        XCTAssertEqual(DeviceIdentity.current, "reset-value", "must reset the UserDefaults mirror too")
    }

    func test_currentUUID_reusesAPersistedUUID() {
        // Seed a legacy, non-UUID string through `_resetForTesting` — the same
        // `stored` `@AppStorage` setter path `current`/`currentUUID` use — rather
        // than a raw `UserDefaults.standard.set`, which the static `@AppStorage`
        // wrapper doesn't reliably observe mid-process (see the precedent note on
        // `ShrunkAPIClientTests.test_deviceIdentity_mintsOnceAndSticks`). This
        // actually exercises `currentUUID`'s fallback path, unlike the prior
        // version of this test, which only round-tripped a value it had just
        // written itself (the fallback never fired).
        DeviceIdentity._resetForTesting(to: "not-a-uuid")
        // Prove the seed landed: `current` must observe it before we can trust
        // anything that follows.
        XCTAssertEqual(DeviceIdentity.current, "not-a-uuid")

        let minted = DeviceIdentity.currentUUID
        // The fallback must write its fresh UUID through the shared `stored`
        // setter, so `current` now agrees with what `currentUUID` just minted
        // — modulo case: `current` stays lowercase (R42), `UUID.uuidString`
        // always renders uppercase.
        XCTAssertEqual(DeviceIdentity.current, minted.uuidString.lowercased())
        // Mint-once: a second call reuses the now-valid stored UUID rather than
        // minting again. `UUID` equality is byte-wise, so case is irrelevant here.
        XCTAssertEqual(DeviceIdentity.currentUUID, minted)
    }
}

final class SyncDeviceTests: XCTestCase {
    private var client: ShrunkAPIClient!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        client = ShrunkAPIClient(baseURL: URL(string: "https://api.test")!,
                                 session: URLSession(configuration: config))
    }

    /// Runs `syncDevice` with the given arguments against a stub that echoes
    /// success, and hands back the decoded JSON body.
    private func syncAndCaptureBody(
        locationId: String? = nil,
        categories: [String]? = nil
    ) async -> [String: Any]? {
        let captured = CapturedRequest()
        StubURLProtocol.handler = { request in
            captured.body = request.bodyData()
            return (200, Data(#"{"ok":true}"#.utf8))
        }
        _ = await client.syncDevice(
            deviceId: "ABC-123",
            transactionJWS: "",
            locationId: locationId,
            categories: categories
        )
        // `as? [String: Any]`, not `as! [String: String]` — see the comment on
        // `test_syncDevice_postsTheDeviceIdAndJWS` below for why.
        return try! JSONSerialization.jsonObject(with: captured.body ?? Data()) as? [String: Any]
    }

    // MARK: - P4-F3 explicit clear vs. omitted-key contract
    // Mirrors the Worker's contract (`backend/src/routes/devices.ts`, commit
    // b90f65c): an explicit empty value clears the field server-side; a `nil`
    // argument with nothing in local storage either omits the key (leaving
    // the server value alone).

    func test_syncDevice_explicitEmptyCategoriesSendsAnEmptyArray() async {
        UserDefaults.standard.removeObject(forKey: "shrunk.onboarding_profile")
        let json = await syncAndCaptureBody(categories: [])
        XCTAssertEqual(json?["categories"] as? [String], [],
                        "an explicit empty list must clear categories server-side, not be dropped")
    }

    func test_syncDevice_nilCategoriesOmitsTheKeyWhenNothingIsStoredEither() async {
        UserDefaults.standard.removeObject(forKey: "shrunk.onboarding_profile")
        let json = await syncAndCaptureBody(categories: nil)
        XCTAssertNil(json?["categories"],
                      "nil with nothing stored locally must omit the key, keeping the server value")
    }

    func test_syncDevice_explicitEmptyLocationIdClearsTheStore() async {
        let json = await syncAndCaptureBody(locationId: "")
        XCTAssertEqual(json?["location_id"] as? String, "",
                        "an explicit empty string must clear the store server-side, not be dropped")
    }

    func test_syncDevice_nilLocationIdOmitsTheKeyWhenNothingIsStoredEither() async {
        UserDefaults.standard.removeObject(forKey: "storeLocationId")
        let json = await syncAndCaptureBody(locationId: nil)
        XCTAssertNil(json?["location_id"],
                      "nil with nothing stored locally must omit the key, keeping the server value")
    }

    func test_syncDevice_postsTheDeviceIdAndJWS() async {
        let captured = CapturedRequest()
        StubURLProtocol.handler = { request in
            captured.method = request.httpMethod
            captured.url = request.url?.absoluteString
            captured.body = request.bodyData()
            return (200, Data(#"{"ok":true}"#.utf8))
        }

        let synced = await client.syncDevice(deviceId: "ABC-123", transactionJWS: "aaa.bbb.ccc")

        XCTAssertTrue(synced)
        XCTAssertEqual(captured.method, "POST")
        XCTAssertEqual(captured.url, "https://api.test/v1/devices")
        // `as? [String: Any]`, not `as! [String: String]`: the phase-4 method this
        // forwards to also fills in `categories`/`prefs`/`watches` from local
        // storage, so the body is not flat string-to-string — forcing it through
        // `[String: String]` traps the whole test process instead of failing
        // the assertion.
        let json = try! JSONSerialization.jsonObject(with: captured.body ?? Data()) as? [String: Any]
        XCTAssertEqual(json?["device_id"] as? String, "ABC-123")
        XCTAssertEqual(json?["transaction_jws"] as? String, "aaa.bbb.ccc")
    }

    func test_syncDevice_returnsFalseOnServerError() async {
        StubURLProtocol.handler = { _ in (500, Data()) }
        let synced = await client.syncDevice(deviceId: "ABC-123", transactionJWS: "aaa.bbb.ccc")
        XCTAssertFalse(synced)
    }
}

/// Reference box so the URLProtocol closure can hand values back to the test.
/// `URLRequest.bodyData()` itself is not redeclared here — Phase 4 already
/// added it in `ShrunkTests/TestHTTPHelpers.swift`.
final class CapturedRequest: @unchecked Sendable {
    var method: String?
    var url: String?
    var body: Data?
}
