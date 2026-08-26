import Foundation

/// The store-data seam. `ShrunkAPIClient` is the production implementation;
/// tests inject a stub so view models and the alternatives engine never touch
/// the network.
protocol StoreDataProviding: Sendable {
    func locations(zip: String) async throws -> [StoreLocation]
    func liveProduct(barcode: String, locationId: String) async throws -> LivePrice
    func search(term: String, locationId: String) async throws -> [StoreSearchResult]
}

extension ShrunkAPIClient: StoreDataProviding {}

/// The curated-feed seam, used by the alternatives fallback.
protocol TrendingFeedProviding: Sendable {
    func fetch() async -> TrendingFeed
}

extension TrendingFeedService: TrendingFeedProviding {}
