import XCTest
@testable import Shrunk

final class NotificationPreferenceToggleTests: XCTestCase {
    func test_newTogglesDefaultToOn() {
        let prefs = NotificationPreferences.default
        XCTAssertTrue(prefs.sizeDropEnabled)
        XCTAssertTrue(prefs.priceHikeEnabled)
        XCTAssertTrue(prefs.verifiedCaseEnabled)
        XCTAssertTrue(prefs.digestEnabled)
    }

    func test_decodesLegacyJSONWithoutTheNewKeys() {
        let legacy = #"{"paused":false,"quietHoursEnabled":false,"quietHoursStartHour":22,"quietHoursEndHour":8,"minimumShrinkPercent":0.03}"#
        let prefs = NotificationPreferences.decoded(legacy)
        XCTAssertTrue(prefs.sizeDropEnabled)
        XCTAssertTrue(prefs.digestEnabled)
        XCTAssertFalse(prefs.paused)
    }

    func test_roundTripsTheNewToggles() {
        var prefs = NotificationPreferences.default
        prefs.digestEnabled = false
        XCTAssertFalse(NotificationPreferences.decoded(prefs.encoded()).digestEnabled)
    }

    func test_kindTogglePayloadMatchesTheWireNames() {
        var prefs = NotificationPreferences.default
        prefs.priceHikeEnabled = false
        XCTAssertEqual(prefs.kindTogglePayload,
                       ["sizeDrop": true, "priceHike": false, "verifiedCase": true, "digest": true])
    }

    func test_pauseSilencesEveryServerPush() {
        var prefs = NotificationPreferences.default
        prefs.paused = true
        XCTAssertEqual(prefs.kindTogglePayload,
                       ["sizeDrop": false, "priceHike": false, "verifiedCase": false, "digest": false])
    }
}

final class GroceryCategoryFeedTests: XCTestCase {
    func test_mapsEveryCategoryToTheBackendName() {
        XCTAssertEqual(GroceryCategory.snacks.feedCategory, "Snacks")
        XCTAssertEqual(GroceryCategory.drinks.feedCategory, "Beverages")
        XCTAssertEqual(GroceryCategory.dairy.feedCategory, "Dairy")
        XCTAssertEqual(GroceryCategory.cleaning.feedCategory, "Cleaning")
        XCTAssertEqual(GroceryCategory.personal.feedCategory, "Personal care")
        XCTAssertEqual(GroceryCategory.paper.feedCategory, "Paper products")
    }
}

/// Named for Phase 4 so it cannot collide with the `DeviceIdentityTests` class
/// Phase 5's Task 5 adds to the same test target.
final class DeviceIdentityUnificationTests: XCTestCase {
    func test_deviceIdentityIsStableAndUnmodifiedByThisPhase() {
        UserDefaults.standard.removeObject(forKey: DeviceIdentity.key)
        let minted = DeviceIdentity.current
        XCTAssertNotNil(UUID(uuidString: minted))
        XCTAssertEqual(DeviceIdentity.key, "device_id")   // Phase 2's key, untouched
        XCTAssertEqual(DeviceIdentity.current, minted, "reading it again must not mint a second id")
    }
}

/// Likewise named for Phase 4: Phase 5's Task 5 adds a `SyncDeviceTests`.
final class DeviceSyncPayloadTests: XCTestCase {
    private var client: ShrunkAPIClient!
    private let defaults = UserDefaults.standard

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        client = ShrunkAPIClient(baseURL: URL(string: "https://api.test")!, session: URLSession(configuration: config))
        defaults.removeObject(forKey: ShrunkAPIClient.apnsTokenKey)
        defaults.removeObject(forKey: "storeLocationId")
        defaults.removeObject(forKey: "shrunk.onboarding_profile")
        defaults.removeObject(forKey: NotificationPreferences.appStorageKey)
    }

    override func tearDown() {
        defaults.removeObject(forKey: ShrunkAPIClient.apnsTokenKey)
        defaults.removeObject(forKey: "storeLocationId")
        defaults.removeObject(forKey: "shrunk.onboarding_profile")
        defaults.removeObject(forKey: NotificationPreferences.appStorageKey)
        super.tearDown()
    }

    /// Captures the one request the stub sees.
    private final class Captured: @unchecked Sendable {
        var url: String?
        var method: String?
        var body: [String: Any]?
    }

    private func capture(status: Int = 200) -> Captured {
        let captured = Captured()
        StubURLProtocol.handler = { request in
            captured.url = request.url?.absoluteString
            captured.method = request.httpMethod
            if let data = request.bodyData() {
                captured.body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
            return (status, Data(#"{"ok":true,"pro":false}"#.utf8))
        }
        return captured
    }

    func test_syncDevice_postsEverythingItWasGiven() async {
        let captured = capture()

        let ok = await client.syncDevice(
            deviceId: "6F9619FF-8B86-D011-B42D-00CF4FC964FF",
            transactionJWS: "aaa.bbb.ccc",
            apnsToken: "a1b2c3",
            locationId: "01400943",
            categories: ["Snacks", "Beverages"],
            watches: [DeviceWatch(gtin: "0052000133417", brand: "Gatorade", alertEnabled: true)]
        )

        XCTAssertTrue(ok)
        XCTAssertEqual(captured.url, "https://api.test/v1/devices")
        XCTAssertEqual(captured.method, "POST")

        let body = try! XCTUnwrap(captured.body)
        XCTAssertEqual(body["device_id"] as? String, "6F9619FF-8B86-D011-B42D-00CF4FC964FF")
        XCTAssertEqual(body["transaction_jws"] as? String, "aaa.bbb.ccc")
        XCTAssertEqual(body["apns_token"] as? String, "a1b2c3")
        XCTAssertEqual(body["location_id"] as? String, "01400943")
        XCTAssertEqual(body["categories"] as? [String], ["Snacks", "Beverages"])
        XCTAssertEqual(body["prefs"] as? [String: Bool],
                       ["sizeDrop": true, "priceHike": true, "verifiedCase": true, "digest": true])

        let watches = try! XCTUnwrap(body["watches"] as? [[String: Any]])
        XCTAssertEqual(watches.count, 1)
        XCTAssertEqual(watches[0]["gtin"] as? String, "0052000133417")
        XCTAssertEqual(watches[0]["brand"] as? String, "Gatorade")
        XCTAssertEqual(watches[0]["alert_enabled"] as? Bool, true)
    }

    func test_syncDevice_isCallableWithJustTheTwoPhase5Arguments() async {
        let captured = capture()
        let ok = await client.syncDevice(deviceId: "device-1", transactionJWS: "aaa.bbb.ccc")
        XCTAssertTrue(ok)

        let body = try! XCTUnwrap(captured.body)
        XCTAssertEqual(body["device_id"] as? String, "device-1")
        XCTAssertEqual(body["transaction_jws"] as? String, "aaa.bbb.ccc")
        XCTAssertNil(body["watches"], "an omitted watch list must not clear the server's copy")
    }

    func test_syncDevice_fillsTheGapsFromLocalStorage() async {
        defaults.set("cafe01", forKey: ShrunkAPIClient.apnsTokenKey)
        defaults.set("01400943", forKey: "storeLocationId")
        var profile = OnboardingProfile.empty
        profile.categories = [.drinks, .snacks]
        defaults.set(profile.encoded(), forKey: "shrunk.onboarding_profile")
        var prefs = NotificationPreferences.default
        prefs.digestEnabled = false
        defaults.set(prefs.encoded(), forKey: NotificationPreferences.appStorageKey)

        let captured = capture()
        await client.syncDevice(deviceId: "device-1", transactionJWS: "")

        let body = try! XCTUnwrap(captured.body)
        XCTAssertEqual(body["apns_token"] as? String, "cafe01")
        XCTAssertEqual(body["location_id"] as? String, "01400943")
        XCTAssertEqual(body["categories"] as? [String], ["Beverages", "Snacks"])
        XCTAssertEqual((body["prefs"] as? [String: Bool])?["digest"], false)
        XCTAssertNil(body["transaction_jws"], "an empty JWS is omitted, not sent as \"\"")
    }

    func test_syncDevice_sendsAnEmptyWatchListWhenAsked() async {
        let captured = capture()
        await client.syncDevice(deviceId: "device-1", transactionJWS: "", watches: [])
        // `[String: Any]` isn't Equatable, so an empty watch list is asserted by
        // presence + count rather than `XCTAssertEqual(..., [])`.
        let watches = try! XCTUnwrap((try! XCTUnwrap(captured.body))["watches"] as? [[String: Any]])
        XCTAssertTrue(watches.isEmpty)
    }

    func test_syncDevice_returnsFalseAndNeverThrowsOnFailure() async {
        _ = capture(status: 500)
        let ok = await client.syncDevice(deviceId: "device-1", transactionJWS: "")
        XCTAssertFalse(ok)
    }
}
