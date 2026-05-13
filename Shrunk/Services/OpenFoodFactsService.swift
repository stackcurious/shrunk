import Foundation

enum ShrunkError: LocalizedError {
    case productNotFound
    case invalidResponse
    case network(Error)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .productNotFound:    return "Not in our database yet."
        case .invalidResponse:    return "We couldn't read the response from the data source."
        case .network(let e):     return e.localizedDescription
        case .decoding(let e):    return "Couldn't read product data. (\(e.localizedDescription))"
        }
    }
}

actor OpenFoodFactsService {
    static let shared = OpenFoodFactsService()

    private let currentBaseURL = URL(string: "https://world.openfoodfacts.org/api/v2")!
    /// Historical revisions sit on the v0 endpoint with `?rev=N`. The shape is
    /// essentially identical to v2 — same product fields — but the URL differs.
    private let revisionBaseURL = URL(string: "https://world.openfoodfacts.org/api/v0")!

    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = d
    }

    /// Fetches the current product AND its earliest known revision in parallel.
    /// If rev=1 reveals a different quantity, we prepend that as a real historical
    /// SizeRecord so `ShrinkDetector` can compute a verdict instead of giving up
    /// on `.insufficientData`. This is the biggest single source of "real data"
    /// in the scanning flow.
    func fetchProduct(barcode: String) async throws -> ShrunkProduct {
        async let currentTask: OFFProduct = fetchOFFProduct(at: currentURL(for: barcode))

        // Revision lookups are best-effort. Network errors / not-found / parse
        // failures here must not break the primary scan flow — wrap to nil.
        async let earliestTask: OFFProduct? = {
            do {
                return try await self.fetchOFFProduct(at: self.revisionURL(for: barcode, rev: 1))
            } catch {
                return nil
            }
        }()

        let current = try await currentTask
        let earliest = await earliestTask

        return Self.mapToProduct(current: current, earliest: earliest, barcode: barcode)
    }

    // MARK: - URL builders

    private func currentURL(for barcode: String) -> URL {
        currentBaseURL.appending(path: "product").appending(path: "\(barcode).json")
    }

    private func revisionURL(for barcode: String, rev: Int) -> URL {
        let base = revisionBaseURL
            .appending(path: "product")
            .appending(path: "\(barcode).json")
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "rev", value: String(rev))]
        return comps?.url ?? base
    }

    // MARK: - Core fetch

    /// Loads + parses a single OFF product URL. Throws on network / status / decode
    /// errors. Surfaces `.productNotFound` for status=0 from the API.
    private func fetchOFFProduct(at url: URL) async throws -> OFFProduct {
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

        let parsed: OFFResponse
        do {
            parsed = try decoder.decode(OFFResponse.self, from: data)
        } catch {
            throw ShrunkError.decoding(error)
        }

        guard parsed.status == 1, let product = parsed.product else {
            throw ShrunkError.productNotFound
        }
        return product
    }

    // MARK: - Mapping

    static func mapToProduct(current: OFFProduct, earliest: OFFProduct?, barcode: String) -> ShrunkProduct {
        let name = current.productName?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            ?? current.genericName?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            ?? "Unknown product"

        let brand = current.brands?
            .components(separatedBy: ",")
            .first?
            .trimmingCharacters(in: .whitespaces) ?? ""

        let category = (current.categoriesTags?.last)
            .map { $0.replacingOccurrences(of: "en:", with: "").replacingOccurrences(of: "-", with: " ") }
            .map { $0.split(separator: " ").map { $0.capitalized }.joined(separator: " ") }
            ?? "Uncategorized"

        return ShrunkProduct(
            id: barcode,
            name: name,
            brand: brand,
            category: category,
            imageURL: current.imageUrl.flatMap(URL.init),
            sizeHistory: buildHistory(current: current, earliest: earliest),
            currentPrice: nil,
            currency: "USD"
        )
    }

    /// Builds the richest sizeHistory we can from three potential signals,
    /// in order of preference:
    ///
    /// 1. `quantity` (current) — almost always present
    /// 2. `quantity_imported` (brand-supplied "original") — present for ~10–15%
    ///    of OFF entries
    /// 3. The `quantity` field from revision 1 — fetched live, fills in cases
    ///    where neither of the above gives us a "before" point
    ///
    /// Result is deduped: if all three sources agree, we still ship 1 record
    /// (no false shrink). If any differ, we get a real before/after.
    static func buildHistory(current: OFFProduct, earliest: OFFProduct?) -> [SizeRecord] {
        var records: [SizeRecord] = []

        let currentDate = current.lastModifiedT.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()
        let createdDate = current.createdT.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            ?? currentDate.addingTimeInterval(-365 * 24 * 60 * 60)

        guard let currentParsed = parseQuantity(current.quantity ?? "") else {
            return records
        }
        let currentRecord = SizeRecord(
            date: currentDate,
            quantity: currentParsed.quantity,
            unit: currentParsed.unit,
            source: "openfoodfacts"
        )
        records.append(currentRecord)

        // Signal 2: brand-supplied quantity_imported. Treat as the original
        // shelf size when present and meaningfully different from current.
        if let imported = parseQuantity(current.quantityImported ?? ""),
           differs(imported, currentParsed) {
            records.insert(SizeRecord(
                date: createdDate,
                quantity: imported.quantity,
                unit: imported.unit,
                source: "openfoodfacts_import"
            ), at: 0)
        }

        // Signal 3: rev=1 quantity. Only used when the first two signals didn't
        // already give us a "before" — avoids inserting duplicate history points.
        if records.count == 1,
           let earliest,
           let earliestParsed = parseQuantity(earliest.quantity ?? ""),
           differs(earliestParsed, currentParsed) {
            let earliestDate = earliest.lastModifiedT
                .map { Date(timeIntervalSince1970: TimeInterval($0)) }
                ?? createdDate
            records.insert(SizeRecord(
                date: earliestDate,
                quantity: earliestParsed.quantity,
                unit: earliestParsed.unit,
                source: "openfoodfacts_rev1"
            ), at: 0)
        }

        return records
    }

    /// Compare two parsed quantities. Counts as "differs" if EITHER the unit
    /// differs (5 oz vs 5 fl oz) OR the magnitudes differ by >1%. The 1%
    /// tolerance keeps rounding artifacts in OFF data from creating phantom
    /// shrinks.
    private static func differs(_ a: (quantity: Double, unit: String),
                                _ b: (quantity: Double, unit: String)) -> Bool {
        if a.unit != b.unit { return true }
        guard b.quantity > 0 else { return false }
        return abs(a.quantity - b.quantity) / b.quantity > 0.01
    }

    /// Parses strings like "28 fl oz", "500g", "1.5L", "12 count", "12ct" into
    /// a numeric quantity and a normalized unit string.
    static func parseQuantity(_ raw: String) -> (quantity: Double, unit: String)? {
        let normalized = raw
            .lowercased()
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let pattern = #/(?<qty>\d+(?:\.\d+)?)\s*(?<unit>fl\s?oz|floz|oz|kg|g|ml|l|count|ct|pk)\b/#
        guard let match = try? pattern.firstMatch(in: normalized) else { return nil }

        let quantity = Double(match.qty) ?? 0
        var unit = String(match.unit)
        if unit == "floz" || unit == "fl oz" { unit = "fl oz" }
        if unit == "ct" || unit == "pk" { unit = "count" }
        return (quantity, unit)
    }
}

// MARK: - OFF API response models

struct OFFResponse: Codable {
    let status: Int
    let product: OFFProduct?
}

struct OFFProduct: Codable {
    let productName: String?
    let genericName: String?
    let brands: String?
    let quantity: String?
    let quantityImported: String?
    let categoriesTags: [String]?
    let imageUrl: String?
    let lastModifiedT: Int?
    let createdT: Int?
}

// MARK: - Helpers

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
