import Foundation

/// Hosted catalog of verified shrinkflation cases. Lives at a versioned URL on
/// jsDelivr (CDN-fronted GitHub) so we can iterate on the dataset without
/// shipping a new app build. Always falls back to a bundled copy on first
/// launch or network failure, so Browse is never blank.
///
/// To update the feed in production: edit `data/trending.json` on the main
/// branch of the GitHub repo; jsDelivr serves the new version on its next
/// cache miss (typically within minutes; can be force-purged via the
/// jsDelivr UI).
actor TrendingFeedService {
    static let shared = TrendingFeedService()

    /// jsDelivr serves files from GitHub at this URL pattern. The `@main`
    /// pins us to the latest commit on main; we could pin to a tag like
    /// `@v1.0.0` for stricter rollouts later.
    private let remoteURL = URL(string: "https://cdn.jsdelivr.net/gh/stackcurious/shrunk@main/data/trending.json")!

    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
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

    /// Force-fetches remote, bypassing the bundled fallback. Used by pull-to-
    /// refresh on Browse. Returns nil if the network is unreachable.
    func fetchRemote() async -> TrendingFeed? {
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 6
        request.cachePolicy = .reloadRevalidatingCacheData

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try decoder.decode(TrendingFeed.self, from: data)
        } catch {
            return nil
        }
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
