import XCTest
@testable import Shrunk

final class ProEntitlementTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        _ productID: String,
        expires: TimeInterval? = 86_400,
        revoked: TimeInterval? = nil
    ) -> ProEntitlement.Snapshot {
        ProEntitlement.Snapshot(
            productID: productID,
            expirationDate: expires.map { now.addingTimeInterval($0) },
            revocationDate: revoked.map { now.addingTimeInterval($0) }
        )
    }

    func test_noEntitlements_isNotPro() {
        XCTAssertFalse(ProEntitlement.isActive([], now: now))
    }

    func test_activeMonthly_isPro() {
        XCTAssertTrue(ProEntitlement.isActive([snapshot(ShrunkProProduct.monthly)], now: now))
    }

    func test_activeYearly_isPro() {
        XCTAssertTrue(ProEntitlement.isActive([snapshot(ShrunkProProduct.yearly)], now: now))
    }

    func test_expiredSubscription_isNotPro() {
        XCTAssertFalse(ProEntitlement.isActive([snapshot(ShrunkProProduct.yearly, expires: -1)], now: now))
    }

    func test_revokedSubscription_isNotPro() {
        XCTAssertFalse(
            ProEntitlement.isActive([snapshot(ShrunkProProduct.yearly, revoked: -3600)], now: now)
        )
    }

    func test_retiredLifetimeSKU_doesNotGrantPro() {
        // com.shrunk.pro.lifetime is removed (spec §2); a stray entitlement for
        // it must not keep an old build's users on Pro through this service.
        XCTAssertFalse(
            ProEntitlement.isActive([snapshot("com.shrunk.pro.lifetime", expires: nil)], now: now)
        )
    }

    func test_anyActiveMemberOfTheGroupIsEnough() {
        let mixed = [
            snapshot(ShrunkProProduct.monthly, expires: -10),
            snapshot(ShrunkProProduct.yearly, expires: 60)
        ]
        XCTAssertTrue(ProEntitlement.isActive(mixed, now: now))
    }

    func test_productIDs_matchTheSpec() {
        XCTAssertEqual(ShrunkProProduct.monthly, "com.shrunk.pro.monthly")
        XCTAssertEqual(ShrunkProProduct.yearly, "com.shrunk.pro.yearly")
        XCTAssertEqual(ShrunkProProduct.all, ["com.shrunk.pro.yearly", "com.shrunk.pro.monthly"])
    }
}
