import XCTest
@testable import Shrunk

final class ShrinkAlertKindTests: XCTestCase {
    private func alert(_ kind: ShrinkAlert.Kind, message: String? = nil) -> ShrinkAlert {
        ShrinkAlert(barcode: "0052000133417", productName: "Gatorade Thirst Quencher", brand: "Gatorade",
                    kind: kind, message: message)
    }

    func test_everyKindHasCopy() {
        XCTAssertEqual(alert(.sizeDrop).headline, "Gatorade just shrank — tap to see the new size.")
        XCTAssertEqual(alert(.priceHike).headline, "Gatorade costs more per unit at your store.")
        XCTAssertEqual(alert(.verifiedCase).headline, "We published a verified case for Gatorade.")
        XCTAssertEqual(alert(.digest).headline, "Your weekly shrink digest is ready.")
        XCTAssertEqual(alert(.unconfirmed).headline, "Possible size change in Gatorade — scan to confirm.")
        XCTAssertEqual(alert(.stable).headline, "Gatorade unchanged — still watching.")
        XCTAssertEqual(alert(.newShrink).headline, "Confirmed shrink. Tap to see details.")
    }

    func test_theServersOwnWordsWin() {
        XCTAssertEqual(alert(.digest, message: "3 new shrinks in Snacks, 1 in Dairy").headline,
                       "3 new shrinks in Snacks, 1 in Dairy")
    }

    func test_confirmedShrinkKinds() {
        XCTAssertTrue(ShrinkAlert.Kind.newShrink.isConfirmedShrink)
        XCTAssertTrue(ShrinkAlert.Kind.sizeDrop.isConfirmedShrink)
        XCTAssertTrue(ShrinkAlert.Kind.verifiedCase.isConfirmedShrink)
        XCTAssertFalse(ShrinkAlert.Kind.priceHike.isConfirmedShrink)
        XCTAssertFalse(ShrinkAlert.Kind.digest.isConfirmedShrink)
        XCTAssertFalse(ShrinkAlert.Kind.unconfirmed.isConfirmedShrink)
        XCTAssertFalse(ShrinkAlert.Kind.stable.isConfirmedShrink)
    }
}

final class ShrinkAlertFromPushTests: XCTestCase {
    private func payload(kind: String, gtin: String?, title: String, body: String) -> [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [
            "kind": kind,
            "aps": ["alert": ["title": title, "body": body], "sound": "default"],
        ]
        if let gtin { userInfo["gtin"] = gtin }
        return userInfo
    }

    func test_mapsASizeDropPush() throws {
        let alert = try XCTUnwrap(ShrinkAlert.from(pushUserInfo: payload(
            kind: "sizeDrop", gtin: "0052000133417",
            title: "Gatorade Thirst Quencher just shrank",
            body: "Now 28 fl oz — was 32 fl oz. Tap to see the history."
        )))
        XCTAssertEqual(alert.kind, .sizeDrop)
        XCTAssertEqual(alert.barcode, "0052000133417")
        XCTAssertEqual(alert.productName, "Gatorade Thirst Quencher")
        XCTAssertEqual(alert.headline, "Now 28 fl oz — was 32 fl oz. Tap to see the history.")
        XCTAssertFalse(alert.isRead)
    }

    func test_prefersTheServersProductNameOverTheTitle() throws {
        var userInfo = payload(
            kind: "sizeDrop", gtin: "0052000133417",
            title: "Something else entirely",
            body: "Now 28 fl oz"
        )
        userInfo["product_name"] = "Gatorade Thirst Quencher"
        let alert = try XCTUnwrap(ShrinkAlert.from(pushUserInfo: userInfo))
        XCTAssertEqual(alert.productName, "Gatorade Thirst Quencher")
    }

    func test_aWhitespaceOnlyProductNameFallsBackToTheTitle() throws {
        var userInfo = payload(
            kind: "sizeDrop", gtin: "0052000133417",
            title: "Gatorade Thirst Quencher just shrank",
            body: "Now 28 fl oz"
        )
        userInfo["product_name"] = "   "
        let alert = try XCTUnwrap(ShrinkAlert.from(pushUserInfo: userInfo))
        XCTAssertEqual(alert.productName, "Gatorade Thirst Quencher")
    }

    func test_aDigestPushHasNoBarcode() throws {
        let alert = try XCTUnwrap(ShrinkAlert.from(pushUserInfo: payload(
            kind: "digest", gtin: nil, title: "What shrank this week", body: "3 new shrinks in Snacks"
        )))
        XCTAssertEqual(alert.kind, .digest)
        XCTAssertEqual(alert.barcode, "")
    }

    func test_rejectsAPayloadWeDoNotUnderstand() {
        XCTAssertNil(ShrinkAlert.from(pushUserInfo: ["aps": ["alert": ["title": "hi"]]]))
        XCTAssertNil(ShrinkAlert.from(pushUserInfo: payload(kind: "somethingElse", gtin: "1", title: "t", body: "b")))
    }

    func test_unconfirmedFactoryDescribesTheMismatch() {
        let watched = WatchedProduct(barcode: "0052000133417", productName: "Gatorade Thirst Quencher",
                                     brand: "Gatorade", lastKnownSize: 946.353, lastKnownUnit: "ml")
        let alert = ShrinkAlert.unconfirmed(from: watched, liveQuantity: 828.058)
        XCTAssertEqual(alert.kind, .unconfirmed)
        XCTAssertEqual(alert.barcode, "0052000133417")
        XCTAssertEqual(alert.previousQuantity, 946.353)
        XCTAssertEqual(alert.currentQuantity, 828.058)
        XCTAssertEqual(alert.shrinkPercent, (828.058 - 946.353) / 946.353, accuracy: 0.0001)
    }
}
