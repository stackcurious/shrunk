import XCTest
import StoreKit
import StoreKitTest
@testable import Shrunk

/// Records what `StoreKitService` sends to the Worker without touching the network.
final class SpyDeviceSyncer: DeviceSyncing, @unchecked Sendable {
    private(set) var deviceIds: [String] = []
    private(set) var jwsValues: [String] = []

    @discardableResult
    func syncDevice(deviceId: String, transactionJWS: String) async -> Bool {
        deviceIds.append(deviceId)
        jwsValues.append(transactionJWS)
        return true
    }
}

@MainActor
final class StoreKitConfigurationTests: XCTestCase {
    private var session: SKTestSession!
    private var spy: SpyDeviceSyncer!
    private var service: StoreKitService!

    override func tearDown() async throws {
        session?.clearTransactions()
        session = nil
        try await super.tearDown()
    }

    // MARK: - Structural (reads the .storekit JSON directly; never skips)

    /// A real red/green test of `Shrunk.storekit` itself, independent of whether the
    /// local `SKTestSession` daemon is reachable on this machine. This is what stops
    /// a `ShrunkProProduct`/config drift (e.g. a product-id typo) from being masked
    /// by the daemon-unavailable skip below — that skip only fires for the one
    /// symptom this test has already ruled out as the cause of an empty probe.
    func test_storekitConfiguration_declaresTheTwoSubscriptionsWithYearlyTrialOnly() throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "Shrunk", withExtension: "storekit"),
            "Shrunk.storekit was not found in the test bundle"
        )
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let topLevelProducts = (json["products"] as? [[String: Any]]) ?? []
        let groups = try XCTUnwrap(json["subscriptionGroups"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 1, "expected exactly one subscription group")
        let subscriptions = try XCTUnwrap(groups.first?["subscriptions"] as? [[String: Any]])

        let allProductIDs = topLevelProducts.compactMap { $0["productID"] as? String }
            + subscriptions.compactMap { $0["productID"] as? String }
        XCTAssertFalse(
            allProductIDs.contains { $0.localizedCaseInsensitiveContains("lifetime") },
            "the retired lifetime SKU must not be present: \(allProductIDs)"
        )

        let subscriptionIDs = Set(subscriptions.compactMap { $0["productID"] as? String })
        XCTAssertEqual(subscriptionIDs, [ShrunkProProduct.monthly, ShrunkProProduct.yearly])

        let yearly = try XCTUnwrap(subscriptions.first { $0["productID"] as? String == ShrunkProProduct.yearly })
        let monthly = try XCTUnwrap(subscriptions.first { $0["productID"] as? String == ShrunkProProduct.monthly })

        let yearlyOffer = try XCTUnwrap(
            yearly["introductoryOffer"] as? [String: Any],
            "yearly must have an introductory offer"
        )
        XCTAssertEqual(yearlyOffer["paymentMode"] as? String, "free")
        XCTAssertEqual(yearlyOffer["subscriptionPeriod"] as? String, "P1W")

        let monthlyOffer = monthly["introductoryOffer"]
        XCTAssertTrue(
            monthlyOffer == nil || monthlyOffer is NSNull,
            "monthly must not have an introductory offer"
        )
    }

    // MARK: - Shared SKTestSession setup (skips only after the structural test above

    /// Builds a fresh `SKTestSession`-backed `StoreKitService` for one test. Skips
    /// the calling test — instead of failing it — only when the local StoreKit test
    /// daemon itself is unreachable on this machine: creating the session throws an
    /// `SKInternalErrorDomain` error, or the very first `Product.products(for:)`
    /// probe throws that same domain, or (the failure actually observed while
    /// building this file: macOS Developer Mode disabled) the daemon fails silently
    /// — no thrown error — and the probe simply comes back empty. Any other error,
    /// or a non-empty-but-wrong probe result, is a real bug and is not caught here.
    private func requireStoreKitSession() async throws {
        do {
            session = try SKTestSession(configurationFileNamed: "Shrunk")
        } catch let error as NSError where error.domain == "SKInternalErrorDomain" {
            throw XCTSkip(Self.daemonUnavailableMessage(error))
        }
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        spy = SpyDeviceSyncer()
        service = StoreKitService(syncer: spy)

        let probe: [Product]
        do {
            probe = try await Product.products(for: ShrunkProProduct.all)
        } catch let error as NSError where error.domain == "SKInternalErrorDomain" {
            throw XCTSkip(Self.daemonUnavailableMessage(error))
        }
        guard !probe.isEmpty else {
            throw XCTSkip(Self.daemonUnavailableMessage(nil))
        }

        await service.loadProducts()
    }

    private static func daemonUnavailableMessage(_ error: NSError?) -> String {
        let cause = error.map { "(\($0))" } ?? "(Product.products(for:) returned no products)"
        return "SKTestSession unavailable on this machine \(cause); "
            + "test_storekitConfiguration_declaresTheTwoSubscriptionsWithYearlyTrialOnly "
            + "already confirmed Shrunk.storekit itself is correct — "
            + "enable macOS Developer Mode: sudo DevToolsSecurity -enable"
    }

    // MARK: - Trial

    func test_configuration_exposesBothPlansInOneGroup() async throws {
        try await requireStoreKitSession()
        let monthly = try XCTUnwrap(service.monthlyProduct)
        let yearly = try XCTUnwrap(service.yearlyProduct)

        XCTAssertEqual(monthly.id, "com.shrunk.pro.monthly")
        XCTAssertEqual(yearly.id, "com.shrunk.pro.yearly")
        XCTAssertEqual(monthly.displayPrice, "$2.99")
        XCTAssertEqual(yearly.displayPrice, "$14.99")
        XCTAssertEqual(monthly.subscription?.subscriptionPeriod.unit, .month)
        XCTAssertEqual(yearly.subscription?.subscriptionPeriod.unit, .year)
        XCTAssertEqual(
            monthly.subscription?.subscriptionGroupID,
            yearly.subscription?.subscriptionGroupID
        )
    }

    func test_yearly_offersASevenDayFreeTrialToANewCustomer() async throws {
        try await requireStoreKitSession()
        let yearly = try XCTUnwrap(service.yearlyProduct)
        let offer = try XCTUnwrap(yearly.subscription?.introductoryOffer)

        XCTAssertEqual(offer.paymentMode, .freeTrial)
        XCTAssertEqual(offer.period.unit, .week)
        XCTAssertEqual(offer.period.value, 1)
        XCTAssertNil(service.monthlyProduct?.subscription?.introductoryOffer)

        await service.refreshTrialEligibility()
        XCTAssertTrue(service.isTrialEligible)
    }

    // MARK: - Active

    func test_purchasingYearly_makesTheUserProAndSyncsTheJWS() async throws {
        try await requireStoreKitSession()
        let yearly = try XCTUnwrap(service.yearlyProduct)

        try await service.purchase(yearly)

        XCTAssertTrue(service.isProUser)
        // `syncEntitlement()` sends `DeviceIdentity.current` (R42: lowercase),
        // not `currentUUID.uuidString` (Foundation always renders that
        // uppercase regardless of casing on write).
        XCTAssertEqual(spy.deviceIds.last, DeviceIdentity.current)
        let jws = try XCTUnwrap(spy.jwsValues.last)
        XCTAssertEqual(jws.split(separator: ".").count, 3, "expected a three-segment JWS")
    }

    func test_purchasingMonthly_alsoGrantsPro() async throws {
        try await requireStoreKitSession()
        let monthly = try XCTUnwrap(service.monthlyProduct)
        try await service.purchase(monthly)
        XCTAssertTrue(service.isProUser)
    }

    // MARK: - Expired

    func test_expiredSubscription_dropsProAndConsumesTheTrial() async throws {
        try await requireStoreKitSession()
        let yearly = try XCTUnwrap(service.yearlyProduct)
        try await service.purchase(yearly)
        XCTAssertTrue(service.isProUser)

        try session.expireSubscription(productIdentifier: ShrunkProProduct.yearly)
        await service.refreshEntitlements()
        XCTAssertFalse(service.isProUser)

        await service.refreshTrialEligibility()
        XCTAssertFalse(service.isTrialEligible, "the introductory offer is used once per group")
    }

    // MARK: - Restore (P5-T8 fix round 2)

    /// A stale `loadError` from an earlier failed restore/load must not survive a
    /// restore that subsequently succeeds — otherwise the paywall's restore alert
    /// appends old error text to "No purchases to restore." even though `AppStore
    /// .sync()` just succeeded. `setSimulatedError(forAPI:)` deterministically forces
    /// `AppStore.sync()` to fail, then succeed, within one test.
    func test_restore_clearsAStaleLoadErrorOnceItSucceeds() async throws {
        try await requireStoreKitSession()

        try await session.setSimulatedError(.generic(.unknown), forAPI: .appStoreSync)
        await service.restore()
        XCTAssertNotNil(service.loadError, "the simulated AppStore.sync() failure should have set loadError")

        try await session.setSimulatedError(nil, forAPI: .appStoreSync)
        await service.restore()
        XCTAssertNil(service.loadError, "a successful restore must clear a stale loadError")
    }
}
