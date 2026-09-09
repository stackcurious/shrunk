import XCTest
@testable import Shrunk

@MainActor
final class StorePickerViewModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "store-picker-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func test_canSearch_acceptsPlacesAndZIPsButNotWhitespace() {
        let vm = StorePickerViewModel(store: StubStoreData(), defaults: defaults)
        vm.query = "   "
        XCTAssertFalse(vm.canSearch)
        vm.query = "Cincinnati, OH"
        XCTAssertTrue(vm.canSearch)
        vm.query = "45044"
        XCTAssertTrue(vm.canSearch)
    }

    func test_canonicalZIP_acceptsFiveDigitsAndZIPPlusFourOnly() {
        XCTAssertEqual(StorePickerViewModel.canonicalZIP("45209"), "45209")
        XCTAssertEqual(StorePickerViewModel.canonicalZIP("45209-1234"), "45209")
        XCTAssertNil(StorePickerViewModel.canonicalZIP("4520"))
        XCTAssertNil(StorePickerViewModel.canonicalZIP("abc12x345"))
        XCTAssertNil(StorePickerViewModel.canonicalZIP("٤٥٢٠٩"))
    }

    func test_search_loadsLocations() async {
        let stub = StubStoreData()
        stub.locationsResult = .success([.fixture(), .fixture(id: "01400944", name: "Oakley")])
        let vm = StorePickerViewModel(store: stub, defaults: defaults)
        vm.query = "45044"

        await vm.search()

        XCTAssertEqual(stub.zips, ["45044"])
        guard case .loaded(let stores) = vm.state else { return XCTFail("expected .loaded, got \(vm.state)") }
        XCTAssertEqual(stores.map(\.id), ["01400943", "01400944"])
    }

    func test_search_emptyResult() async {
        let stub = StubStoreData()
        stub.locationsResult = .success([])
        let vm = StorePickerViewModel(store: stub, defaults: defaults)
        vm.query = "99999"

        await vm.search()

        XCTAssertEqual(vm.state, .empty)
    }

    func test_search_failureShowsTheKrogerDownCopy() async {
        let stub = StubStoreData()
        stub.locationsResult = .failure(ShrunkError.invalidResponse)
        let vm = StorePickerViewModel(store: stub, defaults: defaults)
        vm.query = "45044"

        await vm.search()

        XCTAssertEqual(vm.state, .failed("Store prices unavailable right now"))
    }

    func test_textSearchResolvesPlaceRanksNearestAndCallsResolvedZIP() async {
        let stub = StubStoreData()
        stub.locationsResult = .success([
            .fixture(id: "far", name: "Far", latitude: 39.30, longitude: -84.50),
            .fixture(id: "near", name: "Near", latitude: 39.141, longitude: -84.421),
            .fixture(id: "unknown", name: "Unknown")
        ])
        let resolver = StubStoreLocationResolver()
        resolver.namedResult = .success(.init(
            postalCode: "45209",
            coordinate: .init(latitude: 39.14, longitude: -84.42)
        ))
        let vm = StorePickerViewModel(store: stub, resolver: resolver, defaults: defaults)
        vm.query = "Kroger Hyde Park"

        await vm.search()

        XCTAssertEqual(resolver.namedQueries, ["Kroger Hyde Park"])
        XCTAssertEqual(stub.zips, ["45209"])
        guard case .loaded(let stores) = vm.state else { return XCTFail("expected stores") }
        XCTAssertEqual(stores.map(\.id), ["near", "far", "unknown"])
        XCTAssertNotNil(stores[0].distanceMiles)
        XCTAssertNil(stores[2].distanceMiles)
    }

    func test_useCurrentLocationLoadsAndRanksStoresOnlyAfterTap() async {
        let stub = StubStoreData()
        stub.locationsResult = .success([.fixture(latitude: 39.14, longitude: -84.42)])
        let resolver = StubStoreLocationResolver()
        resolver.currentResult = .success(.init(
            postalCode: "45209",
            coordinate: .init(latitude: 39.141, longitude: -84.421)
        ))
        let vm = StorePickerViewModel(store: stub, resolver: resolver, defaults: defaults)

        XCTAssertEqual(resolver.currentRequests, 0)
        await vm.useCurrentLocation()

        XCTAssertEqual(resolver.currentRequests, 1)
        XCTAssertEqual(vm.query, "45209")
        XCTAssertEqual(stub.zips, ["45209"])
    }

    func test_locationDeniedKeepsTypedSearchAvailable() async {
        let resolver = StubStoreLocationResolver()
        resolver.currentResult = .failure(StoreLocationResolutionError.denied)
        let vm = StorePickerViewModel(store: StubStoreData(), resolver: resolver, defaults: defaults)
        vm.query = "Cincinnati"

        await vm.useCurrentLocation()

        XCTAssertEqual(vm.state, .failed(StorePickerViewModel.locationDeniedMessage))
        XCTAssertEqual(vm.query, "Cincinnati")
        XCTAssertTrue(vm.canSearch)
    }

    func test_unresolvedTextShowsActionableMessageWithoutCallingKroger() async {
        let stub = StubStoreData()
        let resolver = StubStoreLocationResolver()
        resolver.namedResult = .failure(StoreLocationResolutionError.placeNotFound)
        let vm = StorePickerViewModel(store: stub, resolver: resolver, defaults: defaults)
        vm.query = "nowhere nearby"

        await vm.search()

        XCTAssertEqual(vm.state, .failed(StorePickerViewModel.placeNotFoundMessage))
        XCTAssertTrue(stub.zips.isEmpty)
    }

    func test_select_persistsIdAndName() {
        let vm = StorePickerViewModel(store: StubStoreData(), defaults: defaults)
        vm.select(.fixture())

        XCTAssertEqual(defaults.string(forKey: "storeLocationId"), "01400943")
        XCTAssertEqual(defaults.string(forKey: "storeName"), "Kroger Hyde Park")
        XCTAssertEqual(vm.selectedId, "01400943")
    }

    func test_clear_removesBothKeys() {
        let vm = StorePickerViewModel(store: StubStoreData(), defaults: defaults)
        vm.select(.fixture())
        vm.clear()

        XCTAssertNil(defaults.string(forKey: "storeLocationId"))
        XCTAssertNil(defaults.string(forKey: "storeName"))
        XCTAssertNil(vm.selectedId)
    }

    func test_init_readsTheSavedStore() {
        defaults.set("01400943", forKey: "storeLocationId")
        let vm = StorePickerViewModel(store: StubStoreData(), defaults: defaults)
        XCTAssertEqual(vm.selectedId, "01400943")
    }
}
