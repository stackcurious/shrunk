import Foundation
@testable import Shrunk

/// Shared stub for `StoreDataProviding`. `@unchecked Sendable` because the
/// tests drive it from a single task and only read the recordings afterwards.
final class StubStoreData: StoreDataProviding, @unchecked Sendable {
    var locationsResult: Result<[StoreLocation], Error> = .success([])
    var liveProductResult: Result<LivePrice, Error> = .failure(ShrunkError.productNotFound)
    var searchResult: Result<[StoreSearchResult], Error> = .success([])

    private(set) var zips: [String] = []
    private(set) var searchTerms: [String] = []
    private(set) var searchLocationIds: [String] = []

    func locations(zip: String) async throws -> [StoreLocation] {
        zips.append(zip)
        return try locationsResult.get()
    }

    func liveProduct(barcode: String, locationId: String) async throws -> LivePrice {
        try liveProductResult.get()
    }

    func search(term: String, locationId: String) async throws -> [StoreSearchResult] {
        searchTerms.append(term)
        searchLocationIds.append(locationId)
        return try searchResult.get()
    }
}

/// Stub for the curated feed used by the alternatives fallback.
final class StubTrendingFeed: TrendingFeedProviding, @unchecked Sendable {
    var feed: TrendingFeed = .empty
    func fetch() async -> TrendingFeed { feed }
}

@MainActor
final class StubStoreLocationResolver: StoreLocationResolving {
    var currentResult: Result<ResolvedStorePlace, Error> = .failure(StoreLocationResolutionError.unavailable)
    var namedResult: Result<ResolvedStorePlace, Error> = .failure(StoreLocationResolutionError.placeNotFound)
    private(set) var currentRequests = 0
    private(set) var namedQueries: [String] = []

    func currentPlace() async throws -> ResolvedStorePlace {
        currentRequests += 1
        return try currentResult.get()
    }

    func resolvePlace(named query: String) async throws -> ResolvedStorePlace {
        namedQueries.append(query)
        return try namedResult.get()
    }
}

extension StoreLocation {
    static func fixture(
        id: String = "01400943",
        name: String = "Hyde Park",
        latitude: Double? = nil,
        longitude: Double? = nil
    ) -> StoreLocation {
        StoreLocation(id: id, chain: "KROGER", name: name, addressLine1: "3760 Paxton Ave",
                      city: "Cincinnati", state: "OH", zipCode: "45209",
                      latitude: latitude, longitude: longitude)
    }
}
