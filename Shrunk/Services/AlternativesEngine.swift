import Foundation

/// Ranks in-stock products in the same category at the user's store by cost per
/// ounce, cheapest first. Without a store — or when Kroger is unreachable — it
/// falls back to curated verified cases in the same category (spec §7, §8).
struct AlternativesEngine {
    /// Spec §3 — free sees 3 alternatives, Pro sees all of them.
    private let freeLimit = 3

    private let store: any StoreDataProviding
    private let feed: any TrendingFeedProviding

    init(store: any StoreDataProviding = ShrunkAPIClient.shared,
         feed: any TrendingFeedProviding = TrendingFeedService.shared) {
        self.store = store
        self.feed = feed
    }

    func findAlternatives(
        for product: ShrunkProduct,
        shrinkRecord: ShrinkRecord,
        locationId: String?,
        isPro: Bool
    ) async -> AlternativesResult {
        guard !product.category.isEmpty else { return .empty }

        // Only compare like with like. Without a known kind — no size history,
        // or an "unknown" unit — mass and volume candidates would be ranked
        // together by numerically-incomparable $/oz vs $/fl oz, so skip the
        // store search entirely and go straight to curated (spec §7, §8).
        let scannedKind: String? = shrinkRecord.currentSize
            .map(\.unitKind)
            .flatMap { $0 == "unknown" ? nil : $0 }

        if let locationId, let scannedKind {
            let rows = await storeAlternatives(for: product, record: shrinkRecord, scannedKind: scannedKind, locationId: locationId)
            if !rows.isEmpty { return cap(rows, isPro: isPro, isCurated: false) }
        }
        return cap(await curatedAlternatives(for: product), isPro: isPro, isCurated: true)
    }

    // MARK: - Store search

    private func storeAlternatives(
        for product: ShrunkProduct,
        record: ShrinkRecord,
        scannedKind: String,
        locationId: String
    ) async -> [Alternative] {
        let results: [StoreSearchResult]
        do {
            results = try await store.search(term: product.category, locationId: locationId)
        } catch {
            return []   // Kroger never blocks the screen (spec §8)
        }

        let scannedCostPerOz = record.costPerUnitNow

        return results
            .filter { $0.gtin != product.id }
            .filter { $0.inStock }
            .filter { $0.unitKind == scannedKind }
            .compactMap { result -> (StoreSearchResult, Double)? in
                guard let cost = Self.costPerOunce(result) else { return nil }
                return (result, cost)
            }
            .sorted { $0.1 < $1.1 }
            .map { makeAlternative(from: $0.0, costPerOz: $0.1, scannedCostPerOz: scannedCostPerOz) }
    }

    /// The candidate's price in the same oz-equivalent space `ShrinkDetector`
    /// uses, so it is directly comparable with `record.costPerUnitNow`
    /// (shared with `LivePricePanel.costPerOunce` — Phase 3 review T17).
    static func costPerOunce(_ result: StoreSearchResult) -> Double? {
        ShrinkDetector.costPerOunce(price: result.effectivePrice, quantity: result.quantity, unitKind: result.unitKind)
    }

    private func makeAlternative(
        from result: StoreSearchResult,
        costPerOz: Double,
        scannedCostPerOz: Double?
    ) -> Alternative {
        let savings: Double? = scannedCostPerOz.flatMap { scanned in
            scanned > 0 ? ((scanned - costPerOz) / scanned) * 100 : nil
        }

        let verdict: String
        if let savings, savings > 0 {
            verdict = "\(Int(savings.rounded()))% cheaper per oz at your store."
        } else if let price = result.effectivePrice {
            verdict = "\(price.formattedPrice()) · \(costPerOz.formattedCostPerUnit()) per oz at your store."
        } else {
            verdict = "In stock at your store."
        }

        return Alternative(
            id: result.gtin ?? result.productId,
            name: result.description,
            brand: result.brand,
            size: result.size ?? "",
            costPerUnit: costPerOz,
            savingsPercent: savings,
            imageURL: result.imageURL,
            verdict: verdict,
            source: .store,
            price: result.effectivePrice,
            stockLabel: result.stockLabel
        )
    }

    // MARK: - Curated fallback

    private func curatedAlternatives(for product: ShrunkProduct) async -> [Alternative] {
        let category = product.category.lowercased()
        return await feed.fetch().trending
            .filter { $0.barcode != product.id }
            .filter { $0.category.lowercased() == category }
            .map { entry in
                Alternative(
                    id: entry.barcode,
                    name: entry.name,
                    brand: entry.brand,
                    size: entry.history.last.map { $0.quantity.formattedQuantity(unit: $0.unit) } ?? "",
                    costPerUnit: nil,
                    savingsPercent: nil,
                    imageURL: entry.imageUrl,
                    verdict: "Verified shrink on record — tap for the evidence.",
                    source: .curated,
                    price: nil,
                    stockLabel: nil
                )
            }
    }

    // MARK: - Pro gating

    private func cap(_ rows: [Alternative], isPro: Bool, isCurated: Bool) -> AlternativesResult {
        guard !isPro, rows.count > freeLimit else {
            return AlternativesResult(alternatives: rows, hiddenCount: 0, isCurated: isCurated)
        }
        return AlternativesResult(
            alternatives: Array(rows.prefix(freeLimit)),
            hiddenCount: rows.count - freeLimit,
            isCurated: isCurated
        )
    }
}
