import Foundation

/// Fallback product lookup when Open Food Facts has no record for a barcode.
/// UPCitemDB provides current product metadata (title, brand, size, recent
/// prices) but no edit history, so any product fetched here will surface
/// as `.insufficientData` in the verdict — that's honest, not a bug.
///
/// Free tier: 500 requests/day across all users. Treat as a strict fallback,
/// never as a primary source.
actor UPCItemDBService {
    static let shared = UPCItemDBService()

    private let baseURL = URL(string: "https://api.upcitemdb.com/prod/trial/lookup")!
    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session
        self.decoder = JSONDecoder()
    }

    func fetchProduct(barcode: String) async throws -> ShrunkProduct {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ShrunkError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "upc", value: barcode)]
        guard let url = components.url else { throw ShrunkError.invalidResponse }

        let data: Data
        do {
            let (received, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw ShrunkError.invalidResponse
            }
            data = received
        } catch let error as ShrunkError {
            throw error
        } catch {
            throw ShrunkError.network(error)
        }

        let parsed: UPCItemDBResponse
        do {
            parsed = try decoder.decode(UPCItemDBResponse.self, from: data)
        } catch {
            throw ShrunkError.decoding(error)
        }

        guard parsed.code == "OK", let item = parsed.items.first else {
            throw ShrunkError.productNotFound
        }
        return Self.mapToProduct(item, barcode: barcode)
    }

    static func mapToProduct(_ item: UPCItemDBItem, barcode: String) -> ShrunkProduct {
        let history: [SizeRecord]
        if let parsed = OpenFoodFactsService.parseQuantity(item.size ?? "") {
            history = [
                SizeRecord(
                    date: Date(),
                    quantity: parsed.quantity,
                    unit: parsed.unit,
                    source: "upcitemdb"
                )
            ]
        } else {
            history = []
        }

        // UPCitemDB exposes a recorded-price range; use the lowest as a
        // conservative current price estimate. Better than nothing for cost-per-oz.
        let price = item.lowestRecordedPrice ?? item.highestRecordedPrice

        return ShrunkProduct(
            id: barcode,
            name: item.title ?? "Unknown product",
            brand: item.brand ?? "",
            category: item.category?.split(separator: ",").first.map(String.init) ?? "Uncategorized",
            imageURL: item.images?.first.flatMap(URL.init),
            sizeHistory: history,
            currentPrice: price,
            currency: "USD"
        )
    }
}

// MARK: - UPCitemDB response models

struct UPCItemDBResponse: Codable {
    let code: String
    let total: Int?
    let items: [UPCItemDBItem]
}

struct UPCItemDBItem: Codable {
    let title: String?
    let brand: String?
    let category: String?
    let size: String?
    let images: [String]?
    let lowestRecordedPrice: Double?
    let highestRecordedPrice: Double?

    enum CodingKeys: String, CodingKey {
        case title, brand, category, size, images
        case lowestRecordedPrice  = "lowest_recorded_price"
        case highestRecordedPrice = "highest_recorded_price"
    }
}
