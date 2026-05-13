import Foundation

/// Finds competing products in the same category that give more product per
/// dollar. Ranks by cost-per-oz savings, with no-shrink-history products
/// preferred as tiebreakers (the user is here because they got shrunk —
/// don't recommend something that has also shrunk).
struct AlternativesEngine {

    let session: URLSession
    let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = d
    }

    func findAlternatives(
        for product: ShrunkProduct,
        shrinkRecord: ShrinkRecord
    ) async -> [Alternative] {
        guard !product.category.isEmpty,
              let currentSize = shrinkRecord.currentSize else { return [] }

        let normalizedCurrent = ShrinkDetector.normalize(currentSize).quantity
        let currentCPU: Double? = {
            guard let price = product.currentPrice, normalizedCurrent > 0 else { return nil }
            return price / normalizedCurrent
        }()

        let candidates: [ShrunkProduct]
        do {
            candidates = try await searchByCategory(product.category)
        } catch {
            return []
        }

        return candidates
            .filter { $0.id != product.id }
            .compactMap { buildAlternative(from: $0, currentCPU: currentCPU) }
            .filter { $0.savingsPercent > 0 }
            .sorted { lhs, rhs in
                if lhs.hasShrunkBefore != rhs.hasShrunkBefore { return !lhs.hasShrunkBefore }
                return lhs.savingsPercent > rhs.savingsPercent
            }
            .prefix(5)
            .map { $0 }
    }

    // MARK: - OFF category search

    private func searchByCategory(_ category: String) async throws -> [ShrunkProduct] {
        let slug = category
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? category

        guard let url = URL(string: "https://world.openfoodfacts.org/category/\(slug).json?page_size=20") else {
            return []
        }

        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ShrunkError.invalidResponse
        }

        let parsed = try decoder.decode(OFFCategoryResponse.self, from: data)
        return parsed.products.compactMap { off in
            guard let code = off.code, !code.isEmpty else { return nil }
            return OpenFoodFactsService.mapToProduct(
                current: OFFProduct(
                    productName: off.productName,
                    genericName: off.genericName,
                    brands: off.brands,
                    quantity: off.quantity,
                    quantityImported: off.quantityImported,
                    categoriesTags: off.categoriesTags,
                    imageUrl: off.imageUrl,
                    lastModifiedT: off.lastModifiedT,
                    createdT: off.createdT
                ),
                earliest: nil,
                barcode: code
            )
        }
    }

    // MARK: - Ranking

    private func buildAlternative(
        from candidate: ShrunkProduct,
        currentCPU: Double?
    ) -> Alternative? {
        guard let latest = candidate.sizeHistory.last else { return nil }
        let normalized = ShrinkDetector.normalize(latest).quantity
        guard normalized > 0 else { return nil }

        let candidateCPU: Double
        if let price = candidate.currentPrice {
            candidateCPU = price / normalized
        } else {
            // No price → no honest comparison. Skip.
            return nil
        }

        let savings: Double
        if let currentCPU, currentCPU > 0 {
            savings = ((currentCPU - candidateCPU) / currentCPU) * 100
        } else {
            return nil
        }

        let detector = ShrinkDetector()
        let record = detector.analyze(product: candidate)
        let hasShrunkBefore = record.verdict.isShrink

        let humanSize: String = {
            let q = latest.quantity
            let unit = latest.unit
            if q == q.rounded() {
                return "\(Int(q)) \(unit)"
            }
            return String(format: "%.1f %@", q, unit)
        }()

        let verdictLine: String = {
            let pct = Int(savings.rounded())
            if hasShrunkBefore {
                return "\(pct)% cheaper per oz, but has also shrunk recently."
            } else {
                return "\(pct)% cheaper per oz. No shrink on record."
            }
        }()

        return Alternative(
            id: candidate.id,
            name: candidate.name,
            brand: candidate.brand,
            size: humanSize,
            costPerUnit: candidateCPU,
            savingsPercent: savings,
            hasShrunkBefore: hasShrunkBefore,
            imageURL: candidate.imageURL,
            verdict: verdictLine
        )
    }
}

// MARK: - OFF category endpoint

private struct OFFCategoryResponse: Codable {
    let products: [OFFCategoryProduct]
}

private struct OFFCategoryProduct: Codable {
    let code: String?
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
