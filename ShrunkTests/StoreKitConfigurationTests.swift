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

    override func setUp() async throws {
        try await super.setUp()
        // Gate: local StoreKit testing needs macOS Developer Mode enabled; when it's
        // off, the daemon fails silently (SKInternalErrorDomain Code=3 logged to the
        // console, no thrown Swift error) and product lookups come back empty — skip
        // this class in that one observed case instead of failing the whole suite.
        do {
            session = try SKTestSession(configurationFileNamed: "Shrunk")
        } catch let error as NSError where error.domain == "SKInternalErrorDomain" {
            throw XCTSkip("SKTestSession unavailable on this machine (\(error)) — enable macOS Developer Mode: sudo DevToolsSecurity -enable")
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
            throw XCTSkip("SKTestSession unavailable on this machine (\(error)) — enable macOS Developer Mode: sudo DevToolsSecurity -enable")
        }
        guard !probe.isEmpty else {
            throw XCTSkip("SKTestSession unavailable on this machine (Product.products(for:) returned no products; the local StoreKit daemon is not responding) — enable macOS Developer Mode: sudo DevToolsSecurity -enable")
        }

        await service.loadProducts()
    }

    override func tearDown() async throws {
        session?.clearTransactions()
        session = nil
        try await super.tearDown()
    }

    // MARK: - Trial

    func test_configuration_exposesBothPlansInOneGroup() async throws {
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
        let yearly = try XCTUnwrap(service.yearlyProduct)

        try await service.purchase(yearly)

        XCTAssertTrue(service.isProUser)
        XCTAssertEqual(spy.deviceIds.last, DeviceIdentity.currentUUID.uuidString)
        let jws = try XCTUnwrap(spy.jwsValues.last)
        XCTAssertEqual(jws.split(separator: ".").count, 3, "expected a three-segment JWS")
    }

    func test_purchasingMonthly_alsoGrantsPro() async throws {
        let monthly = try XCTUnwrap(service.monthlyProduct)
        try await service.purchase(monthly)
        XCTAssertTrue(service.isProUser)
    }

    // MARK: - Expired

    func test_expiredSubscription_dropsProAndConsumesTheTrial() async throws {
        let yearly = try XCTUnwrap(service.yearlyProduct)
        try await service.purchase(yearly)
        XCTAssertTrue(service.isProUser)

        try session.expireSubscription(productIdentifier: ShrunkProProduct.yearly)
        await service.refreshEntitlements()
        XCTAssertFalse(service.isProUser)

        await service.refreshTrialEligibility()
        XCTAssertFalse(service.isTrialEligible, "the introductory offer is used once per group")
    }
}
