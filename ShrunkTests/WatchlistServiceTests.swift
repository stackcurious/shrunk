import XCTest
import SwiftData
@testable import Shrunk

/// The write side of `WatchlistService.add` for the single-snapshot product
/// (spec §2, §4). `StubWatchlistSync` / `StubWatchlistStore` are shared with
/// `WatchlistSyncTests`, which covers the sync side of the same calls.
@MainActor
final class WatchlistServiceTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var sync: StubWatchlistSync!
    private var service: WatchlistService!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer(
            for: WatchedProduct.self, ShrinkAlert.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        sync = StubWatchlistSync()
        service = WatchlistService(context: context, store: StubWatchlistStore(), sync: sync)
    }

    private func product(sizeHistory: [SizeRecord]) -> ShrunkProduct {
        ShrunkProduct(
            id: "0052000338317", name: "Gatorade Thirst Quencher", brand: "Gatorade",
            category: "Beverages", imageURL: nil, sizeHistory: sizeHistory,
            currentPrice: 1.89, currency: "USD"
        )
    }

    // MARK: - One observation is enough to watch (spec rule 3)

    func test_addAcceptsASingleObservationRecord() throws {
        let observation = SizeRecord(date: Date(timeIntervalSince1970: 1_517_443_200),
                                     quantity: 946.353, unit: "ml", source: "fdc")
        let product = product(sizeHistory: [observation])
        let record = ShrinkDetector().analyze(product: product)

        // Precondition — this is the shape the old guard pair silently
        // refused to do anything useful with: a baseline, but no comparison.
        XCTAssertNil(record.previousSize)
        XCTAssertNotNil(record.currentSize)

        try service.add(product: product, record: record)

        let watched = try XCTUnwrap(try service.fetch(barcode: "0052000338317"))
        XCTAssertEqual(watched.lastKnownSize, 946.353,
                       "the single observation becomes the baseline a size_drop alert compares against")
        XCTAssertEqual(watched.lastKnownUnit, "ml")
        XCTAssertEqual(watched.productName, "Gatorade Thirst Quencher")
        XCTAssertTrue(watched.alertEnabled)
    }

    func test_addStoresTheAdoptedLiveSizeWhenThatIsAllWeHave() throws {
        // Spec rule 5: a product with no observation whose live Kroger row
        // parses a size is watched on that size.
        let product = product(sizeHistory: [])
        let liveSize = SizeRecord(date: Date(), quantity: 828.058, unit: "ml", source: "kroger")
        let record = ShrinkDetector().analyze(product: product, liveSize: liveSize)

        try service.add(product: product, record: record)

        let watched = try XCTUnwrap(try service.fetch(barcode: "0052000338317"))
        XCTAssertEqual(watched.lastKnownSize, 828.058)
        XCTAssertEqual(watched.lastKnownUnit, "ml")
    }

    // MARK: - The zero-size guard now reports itself (spec rule 4)

    func test_addThrowsWhenThereIsNoSizeToWatch() throws {
        let product = product(sizeHistory: [])
        let record = ShrinkDetector().analyze(product: product)
        XCTAssertNil(record.currentSize, "precondition: nothing to use as a baseline")

        XCTAssertThrowsError(try service.add(product: product, record: record)) { error in
            XCTAssertEqual(error as? WatchlistError, .noSizeToWatch,
                           "a silent `return` here is what made the button do nothing (spec §0)")
        }
        XCTAssertNil(try service.fetch(barcode: "0052000338317"), "nothing may be stored")
    }

    func test_theNoSizeErrorCarriesUserFacingCopy() {
        XCTAssertFalse((WatchlistError.noSizeToWatch.errorDescription ?? "").isEmpty,
                       "every failure surfaces to the user as a toast (rule 4)")
    }

    // MARK: - Re-adding

    func test_reAddingTheSameProductUpdatesTheBaselineInPlace() throws {
        let first = product(sizeHistory: [
            SizeRecord(date: Date(timeIntervalSince1970: 1_517_443_200),
                       quantity: 946.353, unit: "ml", source: "fdc")
        ])
        try service.add(product: first, record: ShrinkDetector().analyze(product: first))

        let second = product(sizeHistory: [
            SizeRecord(date: Date(timeIntervalSince1970: 1_517_443_200),
                       quantity: 946.353, unit: "ml", source: "fdc"),
            SizeRecord(date: Date(timeIntervalSince1970: 1_617_443_200),
                       quantity: 828.058, unit: "ml", source: "user_report")
        ])
        try service.add(product: second, record: ShrinkDetector().analyze(product: second))

        let all = try service.all()
        XCTAssertEqual(all.count, 1, "one row per barcode")
        XCTAssertEqual(all[0].lastKnownSize, 828.058)
    }
}
