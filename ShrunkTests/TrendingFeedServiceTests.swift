import XCTest
@testable import Shrunk

final class TrendingFeedServiceTests: XCTestCase {
    private var service: TrendingFeedService!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        service = TrendingFeedService(baseURL: URL(string: "https://api.test")!,
                                      session: URLSession(configuration: config))
    }

    func test_entryMappingBuildsATwoPointHistory() {
        let item = FeedItemDTO(
            gtin: "0052000133417", name: "Gatorade Thirst Quencher", brand: "Gatorade", category: "Beverages",
            previous_quantity: 946.353, current_quantity: 828.058, unit_kind: "volume",
            shrink_percent: -12.5, observed_at: 1630454400, source: "curated"
        )
        let entry = TrendingFeedService.entry(from: item, bundled: nil)

        XCTAssertEqual(entry.barcode, "0052000133417")
        XCTAssertEqual(entry.name, "Gatorade Thirst Quencher")
        XCTAssertEqual(entry.category, "Beverages")
        XCTAssertEqual(entry.history.count, 2)
        XCTAssertEqual(entry.history[0].quantity, 946.353)
        XCTAssertEqual(entry.history[0].unit, "ml")
        XCTAssertEqual(entry.history[1].quantity, 828.058)
        XCTAssertEqual(entry.history[1].date.timeIntervalSince1970, 1630454400)
        XCTAssertLessThan(entry.history[0].date, entry.history[1].date)
        XCTAssertNil(entry.imageUrl)
    }

    func test_entryMappingBorrowsImageAndEvidenceFromTheBundledCopy() {
        let bundled = TrendingEntry(
            barcode: "0052000133417", name: "Gatorade", brand: "Gatorade", category: "Beverages",
            imageUrl: URL(string: "https://img/gatorade.jpg"), history: [],
            currentPrice: 1.89, currency: "USD",
            evidenceUrl: URL(string: "https://www.mouseprint.org/x"), addedAt: Date(timeIntervalSince1970: 0)
        )
        let item = FeedItemDTO(
            gtin: "0052000133417", name: "Gatorade Thirst Quencher", brand: "Gatorade", category: "Beverages",
            previous_quantity: 946.353, current_quantity: 828.058, unit_kind: "volume",
            shrink_percent: -12.5, observed_at: 1630454400, source: "curated"
        )
        let entry = TrendingFeedService.entry(from: item, bundled: bundled)

        XCTAssertEqual(entry.imageUrl?.absoluteString, "https://img/gatorade.jpg")
        XCTAssertEqual(entry.evidenceUrl?.absoluteString, "https://www.mouseprint.org/x")
        XCTAssertEqual(entry.currentPrice, 1.89)
        XCTAssertEqual(entry.name, "Gatorade Thirst Quencher", "the feed's name wins")
    }

    func test_fetchRemoteCallsTheFeedEndpointAndMaps() async {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.test/v1/feed")
            let json = """
            {"updated":1630454400,"items":[
              {"gtin":"0052000133417","name":"Gatorade Thirst Quencher","brand":"Gatorade","category":"Beverages",
               "previous_quantity":946.353,"current_quantity":828.058,"unit_kind":"volume",
               "shrink_percent":-12.5,"observed_at":1630454400,"source":"curated"}]}
            """
            return (200, Data(json.utf8))
        }

        let feed = await service.fetchRemote()
        let entries = try? XCTUnwrap(feed).trending
        XCTAssertEqual(entries?.count, 1)
        XCTAssertEqual(entries?.first?.barcode, "0052000133417")
        XCTAssertEqual(feed?.updated.timeIntervalSince1970, 1630454400)
    }

    func test_fetchRemoteReturnsNilOnFailure() async {
        StubURLProtocol.handler = { _ in (500, Data()) }
        let feed = await service.fetchRemote()
        XCTAssertNil(feed)
    }

    func test_fetchFallsBackToTheBundledCatalogue() async {
        StubURLProtocol.handler = { _ in (500, Data()) }
        let feed = await service.fetch()
        XCTAssertGreaterThan(feed.trending.count, 0, "the bundled trending.json must ship in the app target")
    }
}
