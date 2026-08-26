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

    /// Uploads a crowd label observation. The server recomputes the confidence
    /// gate (spec §6.3) — `ocrConfidence` is evidence, not a verdict.
    func submitObservation(
        gtin: String,
        quantity: Double,
        unitKind: UnitKind,
        rawText: String,
        ocrConfidence: Double,
        deviceId: String,
        photoJPEG: Data?
    ) async throws -> SubmissionResult {
        let boundary = "shrunk-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appending(path: "v1/observations"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            fields: [
                "gtin": gtin,
                "quantity": String(quantity),
                "unit_kind": unitKind.rawValue,
                "raw_text": rawText,
                "ocr_confidence": String(ocrConfidence),
                "device_id": deviceId
            ],
            photoJPEG: photoJPEG
        )

        let data: Data
        do {
            let (received, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw ShrunkError.invalidResponse
            }
            data = received
        } catch let error as ShrunkError {
            throw error
        } catch {
            throw ShrunkError.network(error)
        }

        let dto: SubmissionDTO
        do {
            dto = try decoder.decode(SubmissionDTO.self, from: data)
        } catch {
            throw ShrunkError.decoding(error)
        }
        guard let status = SubmissionResult.Status(rawValue: dto.status) else {
            throw ShrunkError.invalidResponse
        }
        return SubmissionResult(status: status, confidence: dto.confidence, observationId: dto.observation_id)
    }

    /// Built separately from the request so it can be tested directly — a custom
    /// `URLProtocol` receives `httpBody` as nil, so the wire format is otherwise
    /// unobservable from a stubbed session.
    static func multipartBody(boundary: String, fields: [String: String], photoJPEG: Data?) -> Data {
        var body = Data()
        for key in fields.keys.sorted() {          // sorted so the body is deterministic
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            body.appendString("\(fields[key] ?? "")\r\n")
        }
        if let photoJPEG {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"photo\"; filename=\"label.jpg\"\r\n")
            body.appendString("Content-Type: image/jpeg\r\n\r\n")
            body.append(photoJPEG)
            body.appendString("\r\n")
        }
        body.appendString("--\(boundary)--\r\n")
        return body
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

// MARK: - Crowd submission

struct SubmissionResult: Equatable {
    enum Status: String {
        case accepted, pending
    }

    let status: Status
    let confidence: Double
    let observationId: Int
}

/// Seam for stubbing the upload in `ContributeViewModel` tests.
protocol ObservationSubmitting: Sendable {
    func submitObservation(
        gtin: String,
        quantity: Double,
        unitKind: UnitKind,
        rawText: String,
        ocrConfidence: Double,
        deviceId: String,
        photoJPEG: Data?
    ) async throws -> SubmissionResult
}

extension ShrunkAPIClient: ObservationSubmitting {}

struct SubmissionDTO: Decodable {
    let status: String
    let confidence: Double
    let observation_id: Int
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}
