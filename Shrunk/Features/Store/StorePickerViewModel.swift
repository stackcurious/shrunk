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

    nonisolated static let locationIdKey = "storeLocationId"
    nonisolated static let storeNameKey = "storeName"
    nonisolated static let zipValidationMessage = "Enter a 5-digit ZIP, or search a city or neighborhood."
    nonisolated static let placeNotFoundMessage = "We couldn't find that place. Try a city, neighborhood, or 5-digit ZIP."
    nonisolated static let locationDeniedMessage = "Location is off. Search by city, neighborhood, or ZIP instead."

    @Published var query: String = ""
    @Published private(set) var state: State = .idle
    @Published private(set) var selectedId: String?

    private let store: any StoreDataProviding
    private let resolver: any StoreLocationResolving
    private let defaults: UserDefaults
    private var requestNumber = 0

    convenience init(
        store: any StoreDataProviding = ShrunkAPIClient.shared,
        defaults: UserDefaults = .standard
    ) {
        self.init(store: store, resolver: AppleStoreLocationResolver(), defaults: defaults)
    }

    init(
        store: any StoreDataProviding,
        resolver: any StoreLocationResolving,
        defaults: UserDefaults
    ) {
        self.store = store
        self.resolver = resolver
        self.defaults = defaults
        self.selectedId = defaults.string(forKey: Self.locationIdKey)
    }

    var canSearch: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .idle
            return
        }
        let request = beginRequest()

        if let zip = Self.canonicalZIP(trimmed) {
            await loadStores(zip: zip, origin: nil, request: request)
            return
        }
        if trimmed.allSatisfy(\.isNumber) {
            state = .failed(Self.zipValidationMessage)
            return
        }

        state = .loading
        do {
            let place = try await resolver.resolvePlace(named: trimmed)
            guard request == requestNumber else { return }
            await loadStores(zip: place.postalCode, origin: place.coordinate, request: request)
        } catch {
            guard request == requestNumber else { return }
            state = .failed(Self.placeNotFoundMessage)
        }
    }

    func useCurrentLocation() async {
        let request = beginRequest()
        state = .loading
        do {
            let place = try await resolver.currentPlace()
            guard request == requestNumber else { return }
            query = place.postalCode
            await loadStores(zip: place.postalCode, origin: place.coordinate, request: request)
        } catch StoreLocationResolutionError.denied {
            guard request == requestNumber else { return }
            state = .failed(Self.locationDeniedMessage)
        } catch {
            guard request == requestNumber else { return }
            state = .failed("Couldn't get your location. Search by city or ZIP instead.")
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

    static func canonicalZIP(_ input: String) -> String? {
        let characters = Array(input)
        guard characters.count == 5 || characters.count == 10 else { return nil }
        guard characters.prefix(5).allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        if characters.count == 10 {
            guard characters[5] == "-", characters.suffix(4).allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        }
        return String(characters.prefix(5))
    }

    private func beginRequest() -> Int {
        requestNumber += 1
        return requestNumber
    }

    private func loadStores(zip: String, origin: StoreSearchCoordinate?, request: Int) async {
        state = .loading
        do {
            let stores = try await store.locations(zip: zip)
            guard request == requestNumber else { return }
            let ranked = stores.enumerated()
                .map { (index: $0.offset, store: $0.element.ranked(from: origin)) }
                .sorted {
                    switch ($0.store.distanceMiles, $1.store.distanceMiles) {
                    case let (lhs?, rhs?) where lhs != rhs: return lhs < rhs
                    case (_?, nil): return true
                    case (nil, _?): return false
                    default: return $0.index < $1.index
                    }
                }
                .map(\.store)
            state = ranked.isEmpty ? .empty : .loaded(ranked)
        } catch {
            guard request == requestNumber else { return }
            state = .failed("Store prices unavailable right now")
        }
    }
}
