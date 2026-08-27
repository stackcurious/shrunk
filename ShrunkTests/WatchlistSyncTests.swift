import XCTest
import SwiftData
@testable import Shrunk

/// Records what the watchlist sends to `/v1/devices`.
final class StubWatchlistSync: WatchlistSyncing, @unchecked Sendable {
    private(set) var calls: [[DeviceWatch]?] = []
    var onSync: (() -> Void)?

    func syncDevice(
        deviceId: String,
        transactionJWS: String,
        apnsToken: String?,
        locationId: String?,
        categories: [String]?,
        watches: [DeviceWatch]?
    ) async -> Bool {
        calls.append(watches)
        onSync?()
        return true
    }
}

/// Answers `liveProduct` from a fixture table.
final class StubWatchlistStore: StoreDataProviding, @unchecked Sendable {
    var live: [String: LivePrice] = [:]

    func locations(zip: String) async throws -> [StoreLocation] { [] }
    func search(term: String, locationId: String) async throws -> [StoreSearchResult] { [] }
    func liveProduct(barcode: String, locationId: String) async throws -> LivePrice {
        guard let price = live[barcode] else { throw ShrunkError.productNotFound }
        return price
    }
}

@MainActor
final class WatchlistSyncTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var sync: StubWatchlistSync!
    private var store: StubWatchlistStore!
    private var service: WatchlistService!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer(
            for: WatchedProduct.self, ShrinkAlert.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        sync = StubWatchlistSync()
        store = StubWatchlistStore()
        service = WatchlistService(context: context, store: store, sync: sync)
        UserDefaults.standard.set("01400943", forKey: "storeLocationId")
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "storeLocationId")
        try await super.tearDown()
    }

    private func product(_ barcode: String) -> ShrunkProduct {
        ShrunkProduct(id: barcode, name: "Gatorade Thirst Quencher", brand: "Gatorade", category: "Beverages",
                      imageURL: nil, sizeHistory: [], currentPrice: nil, currency: "USD")
    }

    private func size(_ quantity: Double) -> SizeRecord {
        SizeRecord(date: Date(), quantity: quantity, unit: "ml", source: "fdc")
    }

    private func record(
        _ barcode: String,
        quantity: Double,
        price: Double? = 1.89,
        shrinkPercent: Double = 0,
        verdict: ShrinkRecord.ShrinkVerdict = .insufficientData
    ) -> ShrinkRecord {
        ShrinkRecord(
            product: product(barcode),
            previousSize: nil,
            currentSize: size(quantity),
            shrinkPercent: shrinkPercent,
            priceThen: nil,
            priceNow: price,
            costPerUnitThen: nil,
            costPerUnitNow: nil,
            priceIsFromStoreSnapshot: false,
            verdict: verdict
        )
    }

    private func livePrice(_ barcode: String, quantity: Double?, unitKind: String? = "volume") -> LivePrice {
        LivePrice(gtin: barcode, locationId: "01400943", brand: "Gatorade", description: "Gatorade Thirst Quencher",
                  size: "28 fl oz", quantity: quantity, unitKind: unitKind,
                  regular: 1.89, promo: nil, perUnitEstimate: 0.07, stockLevel: "HIGH")
    }

    private func alerts() throws -> [ShrinkAlert] {
        try context.fetch(FetchDescriptor<ShrinkAlert>())
    }

    func test_addingAWatchSyncsTheWholeList() async throws {
        let synced = expectation(description: "synced")
        sync.onSync = { synced.fulfill() }

        try service.add(product: product("0052000133417"), record: record("0052000133417", quantity: 946.353))
        await fulfillment(of: [synced], timeout: 2)

        let watches = try XCTUnwrap(sync.calls.last ?? nil)
        XCTAssertEqual(watches, [DeviceWatch(gtin: "0052000133417", brand: "Gatorade", alertEnabled: true)])
    }

    func test_togglingAndRemovingAlsoSync() async throws {
        // Wait for the add's own sync first, so its Task cannot land on a later
        // expectation and make this test lie.
        let added = expectation(description: "added")
        sync.onSync = { added.fulfill() }
        try service.add(product: product("0052000133417"), record: record("0052000133417", quantity: 946.353))
        await fulfillment(of: [added], timeout: 2)

        let watched = try XCTUnwrap(try service.fetch(barcode: "0052000133417"))

        let toggled = expectation(description: "toggled")
        sync.onSync = { toggled.fulfill() }
        try service.setAlertEnabled(false, for: watched)
        await fulfillment(of: [toggled], timeout: 2)
        XCTAssertEqual((sync.calls.last ?? nil)?.first?.alertEnabled, false)

        let removed = expectation(description: "removed")
        sync.onSync = { removed.fulfill() }
        try service.remove(watched)
        await fulfillment(of: [removed], timeout: 2)
        XCTAssertEqual(sync.calls.last ?? nil, [])
    }

    func test_liveSizeCheckFilesAnUnconfirmedAlert() async throws {
        try service.add(product: product("0052000133417"), record: record("0052000133417", quantity: 946.353))
        store.live["0052000133417"] = livePrice("0052000133417", quantity: 828.058)

        let mismatches = await service.liveSizeCheck()
        XCTAssertEqual(mismatches.count, 1)
        XCTAssertEqual(mismatches[0].1, 828.058)

        let filed = try alerts()
        XCTAssertEqual(filed.count, 1)
        XCTAssertEqual(filed[0].kind, .unconfirmed)
        XCTAssertEqual(filed[0].barcode, "0052000133417")

        // The live size is a hint, not an observation: the stored size stands.
        XCTAssertEqual(try XCTUnwrap(try service.fetch(barcode: "0052000133417")).lastKnownSize, 946.353)
    }

    func test_liveSizeCheckIgnoresAMatchingOrIncomparableSize() async throws {
        try service.add(product: product("0052000133417"), record: record("0052000133417", quantity: 946.353))

        store.live["0052000133417"] = livePrice("0052000133417", quantity: 946.353)
        let matching = await service.liveSizeCheck()
        XCTAssertTrue(matching.isEmpty)

        store.live["0052000133417"] = livePrice("0052000133417", quantity: 340.194, unitKind: "mass")
        let differentUnitKind = await service.liveSizeCheck()
        XCTAssertTrue(differentUnitKind.isEmpty, "a different unit kind is never compared")

        store.live["0052000133417"] = livePrice("0052000133417", quantity: nil)
        let noQuantity = await service.liveSizeCheck()
        XCTAssertTrue(noQuantity.isEmpty)

        XCTAssertTrue(try alerts().isEmpty)
    }

    func test_liveSizeCheckKeepsThePriceFresh() async throws {
        // Starting price is the record() default, $1.89.
        try service.add(product: product("0052000133417"), record: record("0052000133417", quantity: 946.353))

        // A matching size — no unconfirmed alert — but a new store price.
        store.live["0052000133417"] = LivePrice(
            gtin: "0052000133417", locationId: "01400943", brand: "Gatorade",
            description: "Gatorade Thirst Quencher", size: "32 fl oz",
            quantity: 946.353, unitKind: "volume",
            regular: 2.49, promo: nil, perUnitEstimate: 0.08, stockLevel: "HIGH"
        )
        let matching = await service.liveSizeCheck()
        XCTAssertTrue(matching.isEmpty, "the sweep should keep price fresh even without a size mismatch")

        let watched = try XCTUnwrap(try service.fetch(barcode: "0052000133417"))
        XCTAssertEqual(watched.lastKnownPrice, 2.49)
    }

    func test_liveSizeCheckNeedsAStore() async throws {
        UserDefaults.standard.removeObject(forKey: "storeLocationId")
        try service.add(product: product("0052000133417"), record: record("0052000133417", quantity: 946.353))
        store.live["0052000133417"] = livePrice("0052000133417", quantity: 828.058)
        let mismatches = await service.liveSizeCheck()
        XCTAssertTrue(mismatches.isEmpty)
    }

    func test_liveSizeCheckDoesNotRefileTheSameUnconfirmedAlert() async throws {
        try service.add(product: product("0052000133417"), record: record("0052000133417", quantity: 946.353))
        store.live["0052000133417"] = livePrice("0052000133417", quantity: 828.058)

        let first = await service.liveSizeCheck()
        XCTAssertEqual(first.count, 1)

        let second = await service.liveSizeCheck()
        XCTAssertTrue(second.isEmpty, "the same mismatch shouldn't be re-filed on the next refresh")

        let filed = try alerts()
        XCTAssertEqual(filed.count, 1)
    }

    func test_liveSizeCheckFilesANewAlertWhenTheLiveSizeChangesAgain() async throws {
        try service.add(product: product("0052000133417"), record: record("0052000133417", quantity: 946.353))
        store.live["0052000133417"] = livePrice("0052000133417", quantity: 828.058)
        let first = await service.liveSizeCheck()
        XCTAssertEqual(first.count, 1)

        store.live["0052000133417"] = livePrice("0052000133417", quantity: 709.765)
        let second = await service.liveSizeCheck()
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].1, 709.765)

        let filed = try alerts()
        XCTAssertEqual(filed.count, 2)
    }

    func test_syncToBackendSkipsANetworkCallForAnEmptyWatchlist() async throws {
        await service.syncToBackend()
        XCTAssertTrue(sync.calls.isEmpty, "a periodic/foreground sync with nothing watched has nothing to tell the Worker")
    }

    func test_removingTheLastWatchStillSyncsTheEmptyList() async throws {
        let added = expectation(description: "added")
        sync.onSync = { added.fulfill() }
        try service.add(product: product("0052000133417"), record: record("0052000133417", quantity: 946.353))
        await fulfillment(of: [added], timeout: 2)

        let watched = try XCTUnwrap(try service.fetch(barcode: "0052000133417"))
        let callsBeforeRemove = sync.calls.count

        let removed = expectation(description: "removed")
        sync.onSync = { removed.fulfill() }
        try service.remove(watched)
        await fulfillment(of: [removed], timeout: 2)

        let callsAfterRemove = sync.calls.count
        XCTAssertEqual(callsAfterRemove - callsBeforeRemove, 1, "removing the last watch must still sync exactly once")
        XCTAssertEqual(sync.calls.last ?? nil, [])
    }

    // MARK: - Scanned shrinks (spec §3.5 — not just watched products)

    func test_scanningAShrunkProductFilesANewShrinkAlert() throws {
        let shrunk = record("0052000133417", quantity: 828.058, price: 1.99, shrinkPercent: -12.5, verdict: .significantShrink)
        try service.recordScannedShrink(product: product("0052000133417"), record: shrunk)

        let filed = try alerts()
        XCTAssertEqual(filed.count, 1)
        XCTAssertEqual(filed[0].kind, .newShrink)
        XCTAssertEqual(filed[0].barcode, "0052000133417")
        XCTAssertEqual(filed[0].currentPrice, 1.99)
        XCTAssertEqual(filed[0].shrinkPercent, -12.5)
    }

    func test_rescanningTheSameSizeDoesNotRefile() throws {
        let shrunk = record("0052000133417", quantity: 828.058, price: 1.99, shrinkPercent: -12.5, verdict: .significantShrink)
        try service.recordScannedShrink(product: product("0052000133417"), record: shrunk)
        try service.recordScannedShrink(product: product("0052000133417"), record: shrunk)

        let filed = try alerts()
        XCTAssertEqual(filed.count, 1, "re-scanning the same size shouldn't refile")
    }

    func test_aStableVerdictFilesNoAlert() throws {
        let unchanged = record("0052000133417", quantity: 946.353, price: 1.89, shrinkPercent: 0, verdict: .unchanged)
        try service.recordScannedShrink(product: product("0052000133417"), record: unchanged)

        XCTAssertTrue(try alerts().isEmpty)
    }
}
