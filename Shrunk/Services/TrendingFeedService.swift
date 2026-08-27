import Foundation

/// The Browse feed. Reads `/v1/feed` on the Shrunk Worker — curated verified
/// cases merged with recently accepted crowd and Kroger shrinks (spec §6.1) —
/// and falls back to the bundled `trending.json` when the network is gone, so
/// Browse is never blank (spec §8).
actor TrendingFeedService {
    static let shared = TrendingFeedService()

    private let feedURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    /// Plain decoder: the feed's wire names are already snake_case properties.
    private let feedDecoder = JSONDecoder()

    init(baseURL: URL = ShrunkAPIClient.defaultBaseURL, session: URLSession = .shared) {
        self.feedURL = baseURL.appending(path: "v1/feed")
        self.session = session
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        // History points are flexible — try ISO 8601 first, fall back to YYYY-MM-DD
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            // Try full ISO 8601
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: raw) { return date }
            iso.formatOptions = [.withInternetDateTime]
            if let date = iso.date(from: raw) { return date }
            // Try YYYY-MM-DD (the common case in our hand-curated entries)
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(identifier: "UTC")
            if let date = df.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unparseable date \(raw)")
        }
        self.decoder = d
    }

    /// Fetches the latest feed. Always returns something usable:
    ///  - Network success → fresh remote data
    ///  - Network failure → bundled fallback (still real data, just stale)
    ///  - Bundled missing/corrupt → empty feed (only happens in misbuilt apps)
    func fetch() async -> TrendingFeed {
        if let remote = await fetchRemote() {
            return remote
        }
        if let bundled = loadBundled() {
            return bundled
        }
        return TrendingFeed.empty
    }

    /// Force-fetches the Worker feed, bypassing the bundled fallback. Used by
    /// pull-to-refresh on Browse. Returns nil if the Worker is unreachable.
    func fetchRemote() async -> TrendingFeed? {
        var request = URLRequest(url: feedURL)
        request.timeoutInterval = 6
        request.cachePolicy = .reloadRevalidatingCacheData

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let dto = try feedDecoder.decode(FeedResponseDTO.self, from: data)
            let bundled = loadBundled()?.trending.reduce(into: [String: TrendingEntry]()) { $0[$1.barcode] = $1 } ?? [:]
            return TrendingFeed(
                version: 2,
                updated: Date(timeIntervalSince1970: TimeInterval(dto.updated)),
                trending: dto.items.map { Self.entry(from: $0, bundled: bundled[$0.gtin]) }
            )
        } catch {
            return nil
        }
    }

    /// Maps one feed item onto the model Browse already renders. `/v1/feed`
    /// carries no image, price or evidence link, so those come from the bundled
    /// catalogue when it knows the product.
    static func entry(from item: FeedItemDTO, bundled: TrendingEntry?) -> TrendingEntry {
        let unit = ProductDTO.unit(forKind: item.unit_kind)
        let observed = Date(timeIntervalSince1970: TimeInterval(item.observed_at))
        // The feed dates only the current observation; the earlier point sits a
        // day before so the pair sorts correctly for `ShrinkDetector`.
        let previous = observed.addingTimeInterval(-86_400)

        return TrendingEntry(
            barcode: item.gtin,
            name: item.name,
            brand: item.brand,
            category: item.category,
            imageUrl: bundled?.imageUrl,
            history: [
                TrendingEntry.HistoryPoint(date: previous, quantity: item.previous_quantity, unit: unit),
                TrendingEntry.HistoryPoint(date: observed, quantity: item.current_quantity, unit: unit),
            ],
            currentPrice: bundled?.currentPrice,
            currency: bundled?.currency ?? "USD",
            evidenceUrl: bundled?.evidenceUrl,
            addedAt: observed
        )
    }

    private func loadBundled() -> TrendingFeed? {
        guard let url = Bundle.main.url(forResource: "trending", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(TrendingFeed.self, from: data)
    }
}

// MARK: - Wire formats

struct TrendingFeed: Codable {
    let version: Int
    let updated: Date
    let trending: [TrendingEntry]

    static let empty = TrendingFeed(version: 0, updated: Date(), trending: [])

    enum CodingKeys: String, CodingKey {
        case version, updated, trending
    }
}

struct TrendingEntry: Codable, Identifiable {
    let barcode: String
    let name: String
    let brand: String
    let category: String
    let imageUrl: URL?
    let history: [HistoryPoint]
    let currentPrice: Double?
    let currency: String?
    let evidenceUrl: URL?
    let addedAt: Date

    var id: String { barcode }

    struct HistoryPoint: Codable {
        let date: Date
        let quantity: Double
        let unit: String
    }
}

extension TrendingEntry {
    /// Convert to the in-app `ShrunkProduct` model used by `ShrinkDetector`
    /// and downstream views.
    func toProduct() -> ShrunkProduct {
        ShrunkProduct(
            id: barcode,
            name: name,
            brand: brand,
            category: category,
            imageURL: imageUrl,
            sizeHistory: history.map {
                SizeRecord(date: $0.date, quantity: $0.quantity, unit: $0.unit, source: "trending_feed")
            },
            currentPrice: currentPrice,
            currency: currency ?? "USD"
        )
    }
}

// MARK: - /v1/feed wire format

struct FeedResponseDTO: Decodable {
    let updated: Int
    let items: [FeedItemDTO]
}

struct FeedItemDTO: Decodable {
    let gtin: String
    let name: String
    let brand: String
    let category: String
    let previous_quantity: Double
    let current_quantity: Double
    let unit_kind: String
    let shrink_percent: Double
    let observed_at: Int
    let source: String
}
