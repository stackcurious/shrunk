import XCTest
@testable import Shrunk

final class AlternativesEngineTests: XCTestCase {
    private let detector = ShrinkDetector()

    private func scanned(category: String = "Beverages", price: Double? = 1.89) -> ShrunkProduct {
        ShrunkProduct(
            id: "0028400642255", name: "Gatorade", brand: "Gatorade", category: category,
            imageURL: nil,
            sizeHistory: [
                SizeRecord(date: Date(timeIntervalSince1970: 1_600_000_000), quantity: 946.353, unit: "ml", source: "fdc"),
                SizeRecord(date: Date(timeIntervalSince1970: 1_700_000_000), quantity: 828.058, unit: "ml", source: "fdc")
            ],
            currentPrice: price, currency: "USD", needsConfirmation: false,
            priceHistory: price.map { [PricePoint(date: Date(timeIntervalSince1970: 1_700_000_000), price: $0, perUnitEstimate: nil)] } ?? []
        )
    }

    private func candidate(_ id: String, price: Double, ml: Double, stock: String = "HIGH") -> StoreSearchResult {
        StoreSearchResult(
            gtin: id, productId: "k-\(id)", brand: "Brand", description: "Candidate \(id)",
            category: "Beverages", imageURL: nil, size: "\(Int(ml)) ml", quantity: ml,
            unitKind: "volume", regular: price, promo: 0, stockLevel: stock
        )
    }

    private func engine(_ store: StubStoreData, _ feed: StubTrendingFeed = StubTrendingFeed()) -> AlternativesEngine {
        AlternativesEngine(store: store, feed: feed)
    }

    func test_ranksCheapestPerOunceFirstAndExcludesTheScannedProduct() async {
        let store = StubStoreData()
        store.searchResult = .success([
            candidate("0000000000011", price: 3.00, ml: 1000),   // 0.0030 /ml
            candidate("0028400642255", price: 0.10, ml: 1000),   // the scanned product — excluded
            candidate("0000000000022", price: 1.00, ml: 1000)    // 0.0010 /ml — cheapest
        ])
        let product = scanned()
        let record = detector.analyze(product: product)

        let result = await engine(store).findAlternatives(for: product, shrinkRecord: record, locationId: "01400943", isPro: true)

        XCTAssertEqual(store.searchTerms, ["Beverages"])
        XCTAssertEqual(store.searchLocationIds, ["01400943"])
        XCTAssertEqual(result.alternatives.map(\.id), ["0000000000022", "0000000000011"])
        XCTAssertFalse(result.isCurated)
        XCTAssertEqual(result.hiddenCount, 0)
        XCTAssertEqual(result.alternatives[0].source, .store)
    }

    func test_dropsOutOfStockAndOtherUnitKinds() async {
        let store = StubStoreData()
        var countPack = candidate("0000000000033", price: 1.00, ml: 1000)
        countPack = StoreSearchResult(
            gtin: countPack.gtin, productId: countPack.productId, brand: countPack.brand,
            description: countPack.description, category: countPack.category, imageURL: nil,
            size: "12 ct", quantity: 12, unitKind: "count", regular: 1.0, promo: 0, stockLevel: "HIGH"
        )
        store.searchResult = .success([
            candidate("0000000000011", price: 1.00, ml: 1000, stock: "TEMPORARILY_OUT_OF_STOCK"),
            countPack,
            candidate("0000000000044", price: 2.00, ml: 1000)
        ])
        let product = scanned()
        let record = detector.analyze(product: product)

        let result = await engine(store).findAlternatives(for: product, shrinkRecord: record, locationId: "01400943", isPro: true)

        XCTAssertEqual(result.alternatives.map(\.id), ["0000000000044"])
    }

    func test_freeUsersGetThreeRowsAndAHiddenCount() async {
        let store = StubStoreData()
        store.searchResult = .success((1...5).map { candidate("000000000\($0)0\($0)", price: Double($0), ml: 1000) })
        let product = scanned()
        let record = detector.analyze(product: product)

        let free = await engine(store).findAlternatives(for: product, shrinkRecord: record, locationId: "01400943", isPro: false)
        XCTAssertEqual(free.alternatives.count, 3)
        XCTAssertEqual(free.hiddenCount, 2)

        let pro = await engine(store).findAlternatives(for: product, shrinkRecord: record, locationId: "01400943", isPro: true)
        XCTAssertEqual(pro.alternatives.count, 5)
        XCTAssertEqual(pro.hiddenCount, 0)
    }

    func test_savingsIsComputedAgainstTheScannedCostPerOunce() async {
        let store = StubStoreData()
        // Scanned: $1.89 / 828.058 ml -> normalize() gives oz-equivalents.
        store.searchResult = .success([candidate("0000000000011", price: 1.00, ml: 828.058)])
        let product = scanned()
        let record = detector.analyze(product: product)

        let result = await engine(store).findAlternatives(for: product, shrinkRecord: record, locationId: "01400943", isPro: true)

        let savings = try! XCTUnwrap(result.alternatives[0].savingsPercent)
        XCTAssertEqual(savings, ((1.89 - 1.00) / 1.89) * 100, accuracy: 0.01)
        XCTAssertTrue(result.alternatives[0].verdict.contains("cheaper per oz"))
    }

    func test_noStoreFallsBackToCuratedCasesInTheSameCategory() async {
        let feed = StubTrendingFeed()
        feed.feed = TrendingFeed(version: 1, updated: Date(), trending: [
            TrendingEntry(barcode: "0000000000011", name: "Verified Case", brand: "Brand", category: "Beverages",
                          imageUrl: nil,
                          history: [TrendingEntry.HistoryPoint(date: Date(timeIntervalSince1970: 1_600_000_000), quantity: 32, unit: "fl oz")],
                          currentPrice: nil, currency: "USD", evidenceUrl: nil, addedAt: Date()),
            TrendingEntry(barcode: "0000000000022", name: "Other Category", brand: "Brand", category: "Snacks",
                          imageUrl: nil, history: [], currentPrice: nil, currency: "USD", evidenceUrl: nil, addedAt: Date())
        ])
        let product = scanned()
        let record = detector.analyze(product: product)

        let result = await AlternativesEngine(store: StubStoreData(), feed: feed)
            .findAlternatives(for: product, shrinkRecord: record, locationId: nil, isPro: true)

        XCTAssertTrue(result.isCurated)
        XCTAssertEqual(result.alternatives.map(\.id), ["0000000000011"])
        XCTAssertEqual(result.alternatives[0].source, .curated)
        XCTAssertNil(result.alternatives[0].costPerUnit)
    }

    func test_krogerFailureFallsBackToCurated() async {
        let store = StubStoreData()
        store.searchResult = .failure(ShrunkError.invalidResponse)
        let feed = StubTrendingFeed()
        feed.feed = TrendingFeed(version: 1, updated: Date(), trending: [
            TrendingEntry(barcode: "0000000000011", name: "Verified Case", brand: "Brand", category: "Beverages",
                          imageUrl: nil, history: [], currentPrice: nil, currency: "USD", evidenceUrl: nil, addedAt: Date())
        ])
        let product = scanned()
        let record = detector.analyze(product: product)

        let result = await AlternativesEngine(store: store, feed: feed)
            .findAlternatives(for: product, shrinkRecord: record, locationId: "01400943", isPro: true)

        XCTAssertTrue(result.isCurated)
        XCTAssertEqual(result.alternatives.count, 1)
    }
}
