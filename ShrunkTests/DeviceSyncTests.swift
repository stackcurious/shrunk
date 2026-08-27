import XCTest
@testable import Shrunk

final class DeviceIdentityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: DeviceIdentity.key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: DeviceIdentity.key)
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
        // Phase 2's `current` always mints UUID().uuidString, so the two never diverge.
        XCTAssertEqual(DeviceIdentity.currentUUID.uuidString, DeviceIdentity.current)
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
        // setter, so `current` now agrees with what `currentUUID` just minted.
        XCTAssertEqual(DeviceIdentity.current, minted.uuidString)
        // Mint-once: a second call reuses the now-valid stored UUID rather than
        // minting again.
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
