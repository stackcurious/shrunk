import Foundation

@MainActor
final class StorePickerViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded([StoreLocation])
        case empty
        case failed(String)
    }

    /// The two keys the rest of the app reads with @AppStorage.
    static let locationIdKey = "storeLocationId"
    static let storeNameKey = "storeName"

    @Published var zip: String = ""
    @Published private(set) var state: State = .idle
    @Published private(set) var selectedId: String?

    private let store: any StoreDataProviding
    private let defaults: UserDefaults

    init(store: any StoreDataProviding = ShrunkAPIClient.shared, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        self.selectedId = defaults.string(forKey: Self.locationIdKey)
    }

    var canSearch: Bool { zip.filter(\.isNumber).count == 5 }

    func search() async {
        guard canSearch else { return }
        state = .loading
        do {
            let stores = try await store.locations(zip: zip.filter(\.isNumber))
            state = stores.isEmpty ? .empty : .loaded(stores)
        } catch {
            // Kroger down or key revoked — never a blocking error (spec §8).
            state = .failed("Store prices unavailable right now")
        }
    }

    func select(_ location: StoreLocation) {
        defaults.set(location.id, forKey: Self.locationIdKey)
        defaults.set(location.displayName, forKey: Self.storeNameKey)
        selectedId = location.id
    }

    func clear() {
        defaults.removeObject(forKey: Self.locationIdKey)
        defaults.removeObject(forKey: Self.storeNameKey)
        selectedId = nil
    }
}
