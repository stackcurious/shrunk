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

    func test_canSearch_requiresFiveDigits() {
        let vm = StorePickerViewModel(store: StubStoreData(), defaults: defaults)
        vm.zip = "450"
        XCTAssertFalse(vm.canSearch)
        vm.zip = "45044"
        XCTAssertTrue(vm.canSearch)
    }

    func test_search_loadsLocations() async {
        let stub = StubStoreData()
        stub.locationsResult = .success([.fixture(), .fixture(id: "01400944", name: "Oakley")])
        let vm = StorePickerViewModel(store: stub, defaults: defaults)
        vm.zip = "45044"

        await vm.search()

        XCTAssertEqual(stub.zips, ["45044"])
        guard case .loaded(let stores) = vm.state else { return XCTFail("expected .loaded, got \(vm.state)") }
        XCTAssertEqual(stores.map(\.id), ["01400943", "01400944"])
    }

    func test_search_emptyResult() async {
        let stub = StubStoreData()
        stub.locationsResult = .success([])
        let vm = StorePickerViewModel(store: stub, defaults: defaults)
        vm.zip = "99999"

        await vm.search()

        XCTAssertEqual(vm.state, .empty)
    }

    func test_search_failureShowsTheKrogerDownCopy() async {
        let stub = StubStoreData()
        stub.locationsResult = .failure(ShrunkError.invalidResponse)
        let vm = StorePickerViewModel(store: stub, defaults: defaults)
        vm.zip = "45044"

        await vm.search()

        XCTAssertEqual(vm.state, .failed("Store prices unavailable right now"))
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
