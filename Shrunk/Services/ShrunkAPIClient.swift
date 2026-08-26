import Foundation

/// Client for the Shrunk Worker API. Single source of product identity and
/// size/price history for the scan and watchlist paths.
actor ShrunkAPIClient {
    static let shared = ShrunkAPIClient()

    static var defaultBaseURL: URL {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "useLocalAPI") {
            return URL(string: "http://localhost:8787")!
        }
        #endif
        return URL(string: "https://shrunk-api.REPLACE-ME.workers.dev")!   // set to the URL printed by `wrangler deploy`
    }

    private let baseURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(baseURL: URL = ShrunkAPIClient.defaultBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func fetchProduct(barcode: String, locationId: String?) async throws -> ShrunkProduct {
        var components = URLComponents(url: baseURL.appending(path: "v1/product/\(barcode)"), resolvingAgainstBaseURL: false)!
        if let locationId {
            components.queryItems = [URLQueryItem(name: "locationId", value: locationId)]
        }

        let data: Data
        do {
            let (received, response) = try await session.data(from: components.url!)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200: data = received
            case 404: throw ShrunkError.productNotFound
            default:  throw ShrunkError.invalidResponse
            }
        } catch let error as ShrunkError {
            throw error
        } catch {
            throw ShrunkError.network(error)
        }

        let dto: ProductDTO
        do {
            dto = try decoder.decode(ProductDTO.self, from: data)
        } catch {
            throw ShrunkError.decoding(error)
        }
        return dto.toProduct()
    }
}

// MARK: - Wire format

struct ProductDTO: Decodable {
    let gtin: String
    let name: String
    let brand: String
    let category: String
    let image_url: String?
    let unit_kind: String?
    let observations: [ObservationDTO]
    let price_snapshots: [PriceSnapshotDTO]

    struct ObservationDTO: Decodable {
        let quantity: Double
        let unit_kind: String
        let raw_text: String?
        let observed_at: Int
        let source: String
        let source_ref: String?
        let confidence: Double
    }

    struct PriceSnapshotDTO: Decodable {
        let location_id: String
        let regular: Double?
        let promo: Double?
        let per_unit_estimate: Double?
        let size_raw: String?
        let stock_level: String?
        let observed_at: Int
    }

    static func unit(forKind kind: String) -> String {
        switch kind {
        case "mass":   return "g"
        case "volume": return "ml"
        default:       return "count"
        }
    }

    func toProduct() -> ShrunkProduct {
        let history = observations.map {
            SizeRecord(
                date: Date(timeIntervalSince1970: TimeInterval($0.observed_at)),
                quantity: $0.quantity,
                unit: Self.unit(forKind: $0.unit_kind),
                source: $0.source
            )
        }
        let latestSnapshot = price_snapshots.max { $0.observed_at < $1.observed_at }
        let price: Double? = latestSnapshot.flatMap { snap in
            if let promo = snap.promo, promo > 0 { return promo }
            return snap.regular
        }
        return ShrunkProduct(
            id: gtin,
            name: name,
            brand: brand,
            category: category.isEmpty ? "Uncategorized" : category,
            imageURL: image_url.flatMap(URL.init),
            sizeHistory: history,
            currentPrice: price,
            currency: "USD"
        )
    }
}
