import XCTest
@testable import Shrunk

/// Covers the live-price side of `ResultViewModel.load(barcode:)`/`prebake(product:record:)`
/// (Task 17, spec §7/§8): the panel is additive — a Kroger failure never
/// changes the main product `state`, and the store's `locationId` is what
/// gates whether we fetch a live price at all.
@MainActor
final class ResultViewModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var apiClient: ShrunkAPIClient!

    override func setUp() {
        super.setUp()
        suiteName = "result-vm-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        apiClient = ShrunkAPIClient(baseURL: URL(string: "https://api.test")!, session: URLSession(configuration: config))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func productJSON(gtin: String = "0028400642255") -> String {
        """
        {"gtin":"\(gtin)","name":"Gatorade","brand":"Gatorade","category":"Beverages","image_url":null,"unit_kind":"volume",
         "observations":[{"quantity":946.353,"unit_kind":"volume","raw_text":"32 fl oz","observed_at":1517443200,"source":"fdc","source_ref":"1","confidence":0.9}],
         "price_snapshots":[]}
        """
    }

    private func liveJSON(gtin: String = "0028400642255", locationId: String = "01400943") -> String {
        """
        {"gtin":"\(gtin)","location_id":"\(locationId)","product_id":"k-1","brand":"Gatorade","description":"Gatorade 28oz",
         "category":"Beverages","image_url":null,"size":"28 fl oz","quantity":828.058,"unit_kind":"volume",
         "regular":1.89,"promo":0,"per_unit_estimate":0.07,"price_per_base_unit":null,"stock_level":"HIGH","attribution":"Prices from Kroger"}
        """
    }

    /// A live size that matches `productJSON()`'s single fdc observation
    /// (946.353 ml / 32 fl oz) exactly.
    private func liveJSONMatchingProductSize(gtin: String = "0028400642255", locationId: String = "01400943") -> String {
        """
        {"gtin":"\(gtin)","location_id":"\(locationId)","product_id":"k-1","brand":"Gatorade","description":"Gatorade 32oz",
         "category":"Beverages","image_url":null,"size":"32 fl oz","quantity":946.353,"unit_kind":"volume",
         "regular":1.89,"promo":0,"per_unit_estimate":0.07,"price_per_base_unit":null,"stock_level":"HIGH","attribution":"Prices from Kroger"}
        """
    }

    /// Two observations: an older `fdc` one at 946.353 ml (32 fl oz) and a
    /// *newer* `kroger` one at 828.058 ml (28 fl oz) — the newest observation
    /// overall is Kroger-sourced, but the newest **non-Kroger** one is the fdc
    /// row, which is what the mismatch check must compare against.
    private func productJSONWithNewerKrogerObservation(gtin: String = "0028400642255") -> String {
        """
        {"gtin":"\(gtin)","name":"Gatorade","brand":"Gatorade","category":"Beverages","image_url":null,"unit_kind":"volume",
         "observations":[
           {"quantity":946.353,"unit_kind":"volume","raw_text":"32 fl oz","observed_at":1517443200,"source":"fdc","source_ref":"1","confidence":0.9},
           {"quantity":828.058,"unit_kind":"volume","raw_text":"28 fl oz","observed_at":1617443200,"source":"kroger","source_ref":"01400943","confidence":0.8}
         ],
         "price_snapshots":[]}
        """
    }

    private func makeVM(engine: AlternativesEngine = AlternativesEngine(store: StubStoreData(), feed: StubTrendingFeed())) -> ResultViewModel {
        ResultViewModel(api: apiClient, engine: engine, detector: ShrinkDetector(), defaults: defaults)
    }

    // MARK: - load(barcode:)

    func test_load_noStore_doesNotFetchLivePriceAndStaysHidden() async {
        StubURLProtocol.handler = { request in
            if request.url!.path.contains("/v1/kroger/product") {
                XCTFail("kroger product endpoint should not be called without a store")
                return (500, Data())
            }
            XCTAssertFalse(request.url!.absoluteString.contains("locationId"), request.url!.absoluteString)
            return (200, Data(self.productJSON().utf8))
        }

        let vm = makeVM()
        await vm.load(barcode: "0028400642255")

        XCTAssertEqual(vm.livePrice, .hidden)
        guard case .loaded = vm.state else { return XCTFail("expected .loaded, got \(vm.state)") }
    }

    func test_load_withStore_passesLocationIdAndLoadsLivePrice() async {
        defaults.set("01400943", forKey: StorePickerViewModel.locationIdKey)
        StubURLProtocol.handler = { request in
            let urlString = request.url!.absoluteString
            XCTAssertTrue(urlString.contains("locationId=01400943"), urlString)
            if urlString.contains("/v1/kroger/product") {
                return (200, Data(self.liveJSON().utf8))
            }
            return (200, Data(self.productJSON().utf8))
        }

        let vm = makeVM()
        await vm.load(barcode: "0028400642255")

        guard case .loaded(let live) = vm.livePrice else { return XCTFail("expected .loaded, got \(vm.livePrice)") }
        XCTAssertEqual(live.regular, 1.89)
        XCTAssertEqual(live.locationId, "01400943")
        XCTAssertEqual(live.stockLevel, "HIGH")
    }

    func test_load_liveProductFails_marksUnavailableWithoutAffectingProductState() async {
        defaults.set("01400943", forKey: StorePickerViewModel.locationIdKey)
        StubURLProtocol.handler = { request in
            if request.url!.path.contains("/v1/kroger/product") {
                return (500, Data())
            }
            return (200, Data(self.productJSON().utf8))
        }

        let vm = makeVM()
        await vm.load(barcode: "0028400642255")

        XCTAssertEqual(vm.livePrice, .unavailable)
        guard case .loaded(let product, _) = vm.state else { return XCTFail("expected .loaded, got \(vm.state)") }
        XCTAssertEqual(product.id, "0028400642255")
    }

    func test_load_productNotFound_setsLivePriceHiddenEvenWithAStore() async {
        defaults.set("01400943", forKey: StorePickerViewModel.locationIdKey)
        StubURLProtocol.handler = { _ in (404, Data()) }

        let vm = makeVM()
        await vm.load(barcode: "0000000000000")

        XCTAssertEqual(vm.livePrice, .hidden)
        guard case .notFound = vm.state else { return XCTFail("expected .notFound, got \(vm.state)") }
    }

    // MARK: - live-size mismatch (Phase 3 review I5)
    //
    // The server derives `needs_confirmation` from a *stored* `kroger`
    // observation, so it's one scan late (written after the response that
    // needed it) and dead entirely when `KROGER_PERSIST=off` never writes
    // one. These compute the mismatch client-side, on the very first scan,
    // from the just-fetched `LivePrice` against the newest non-Kroger
    // `SizeRecord` — independent of whatever the server flag says.

    func test_load_liveSizeMismatchesLatestObservation_setsFlagEvenWhenServerFlagIsFalse() async {
        defaults.set("01400943", forKey: StorePickerViewModel.locationIdKey)
        StubURLProtocol.handler = { request in
            if request.url!.path.contains("/v1/kroger/product") {
                // 828.058 ml (28 fl oz) live vs. the 946.353 ml (32 fl oz) fdc
                // observation in productJSON() — a real >1% mismatch, with no
                // stored `kroger` observation anywhere (the KROGER_PERSIST=off
                // scenario: needs_confirmation is absent from the server JSON).
                return (200, Data(self.liveJSON().utf8))
            }
            return (200, Data(self.productJSON().utf8))
        }

        let vm = makeVM()
        await vm.load(barcode: "0028400642255")

        guard case .loaded(let product, _) = vm.state else { return XCTFail("expected .loaded, got \(vm.state)") }
        XCTAssertFalse(product.needsConfirmation)
        XCTAssertTrue(vm.liveSizeMismatch)
    }

    func test_load_liveSizeMatchesLatestObservation_doesNotSetFlag() async {
        defaults.set("01400943", forKey: StorePickerViewModel.locationIdKey)
        StubURLProtocol.handler = { request in
            if request.url!.path.contains("/v1/kroger/product") {
                return (200, Data(self.liveJSONMatchingProductSize().utf8))
            }
            return (200, Data(self.productJSON().utf8))
        }

        let vm = makeVM()
        await vm.load(barcode: "0028400642255")

        XCTAssertFalse(vm.liveSizeMismatch)
    }

    func test_load_comparesAgainstNewestNonKrogerObservation_ignoringNewerKrogerOne() async {
        defaults.set("01400943", forKey: StorePickerViewModel.locationIdKey)
        StubURLProtocol.handler = { request in
            if request.url!.path.contains("/v1/kroger/product") {
                // Matches the newer *kroger* observation exactly (828.058 ml).
                return (200, Data(self.liveJSON().utf8))
            }
            return (200, Data(self.productJSONWithNewerKrogerObservation().utf8))
        }

        let vm = makeVM()
        await vm.load(barcode: "0028400642255")

        // Must still flag a mismatch — the comparison is against the newest
        // *non-Kroger* observation (fdc, 946.353 ml), not whichever
        // observation happens to be chronologically last.
        XCTAssertTrue(vm.liveSizeMismatch)
    }

    // MARK: - prebake(product:record:)

    func test_prebake_alsoFetchesLivePriceInTheBackground() async {
        defaults.set("01400943", forKey: StorePickerViewModel.locationIdKey)
        StubURLProtocol.handler = { request in
            XCTAssertTrue(request.url!.path.contains("/v1/kroger/product"), request.url!.absoluteString)
            return (200, Data(self.liveJSON().utf8))
        }

        let product = ShrunkProduct(
            id: "0028400642255", name: "Gatorade", brand: "Gatorade", category: "Beverages",
            imageURL: nil, sizeHistory: [], currentPrice: nil, currency: "USD"
        )
        let record = ShrinkDetector().analyze(product: product)

        let vm = makeVM()
        vm.prebake(product: product, record: record)

        // prebake fires the fetch in a detached Task; poll for it to land
        // (bounded — the stub responds synchronously, this converges in a beat).
        // livePrice starts .hidden and the main actor hasn't yielded to the
        // background Task yet, so wait until it moves past .hidden/.loading.
        pollLoop: for _ in 0..<200 {
            switch vm.livePrice {
            case .loaded, .unavailable: break pollLoop
            default: try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }

        guard case .loaded(let live) = vm.livePrice else { return XCTFail("expected .loaded, got \(vm.livePrice)") }
        XCTAssertEqual(live.regular, 1.89)
    }
}
