import XCTest
import SwiftData
@testable import Shrunk

final class PushRegistrationTests: XCTestCase {
    func test_deviceTokenBecomesLowercaseHex() {
        XCTAssertEqual(PushRegistration.hexString(from: Data([0x74, 0x0f, 0x47, 0xff])), "740f47ff")
        XCTAssertEqual(PushRegistration.hexString(from: Data()), "")
    }
}

@MainActor
final class PushInboxTests: XCTestCase {
    private var container: ModelContainer!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer(
            for: WatchedProduct.self, ShrinkAlert.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        PushInbox.shared.container = container
        PushInbox.shared.pendingBarcode = nil
        PushInbox.shared.resetDeduplication()
    }

    private func payload(kind: String, gtin: String?, body: String) -> [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [
            "kind": kind,
            "aps": ["alert": ["title": "Gatorade just shrank", "body": body]],
        ]
        if let gtin { userInfo["gtin"] = gtin }
        return userInfo
    }

    private func storedAlerts() throws -> [ShrinkAlert] {
        try ModelContext(container).fetch(FetchDescriptor<ShrinkAlert>())
    }

    func test_recordWritesTheAlertIntoTheFeed() throws {
        PushInbox.shared.record(userInfo: payload(kind: "sizeDrop", gtin: "0052000133417", body: "Now 28 fl oz"))
        let alerts = try storedAlerts()
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].kind, .sizeDrop)
        XCTAssertEqual(alerts[0].barcode, "0052000133417")
        XCTAssertEqual(alerts[0].headline, "Now 28 fl oz")
    }

    func test_theSamePushIsRecordedOnce() throws {
        let userInfo = payload(kind: "sizeDrop", gtin: "0052000133417", body: "Now 28 fl oz")
        PushInbox.shared.record(userInfo: userInfo)     // background wake
        PushInbox.shared.record(userInfo: userInfo)     // then the user taps it
        XCTAssertEqual(try storedAlerts().count, 1)
    }

    func test_aDifferentPushIsStillRecorded() throws {
        PushInbox.shared.record(userInfo: payload(kind: "sizeDrop", gtin: "0052000133417", body: "Now 28 fl oz"))
        PushInbox.shared.record(userInfo: payload(kind: "priceHike", gtin: "0052000133417", body: "Now $2.10 per unit"))
        XCTAssertEqual(try storedAlerts().count, 2)
    }

    func test_ignoresAPayloadThatIsNotOurs() throws {
        PushInbox.shared.record(userInfo: ["aps": ["alert": "hello"]])
        XCTAssertEqual(try storedAlerts().count, 0)
    }

    func test_tappingAProductPushRoutesToIt() {
        PushInbox.shared.open(userInfo: payload(kind: "sizeDrop", gtin: "0052000133417", body: "b"))
        XCTAssertEqual(PushInbox.shared.pendingBarcode, "0052000133417")
    }

    func test_tappingTheDigestRoutesNowhere() {
        PushInbox.shared.open(userInfo: payload(kind: "digest", gtin: nil, body: "3 new shrinks in Snacks"))
        XCTAssertNil(PushInbox.shared.pendingBarcode)
    }
}
