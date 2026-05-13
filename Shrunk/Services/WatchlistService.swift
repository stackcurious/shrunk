import Foundation
import SwiftData

/// Wraps the SwiftData ModelContext for watched-product CRUD plus the
/// background-refresh entry point. View layer uses `@Query` directly for live
/// fetches; this service handles writes and the off-thread refresh sweep.
@MainActor
final class WatchlistService {
    private let context: ModelContext
    private let off: OpenFoodFactsService
    private let detector: ShrinkDetector

    init(context: ModelContext,
         off: OpenFoodFactsService = .shared,
         detector: ShrinkDetector = ShrinkDetector()) {
        self.context = context
        self.off = off
        self.detector = detector
    }

    // MARK: - CRUD

    func add(product: ShrunkProduct, currentSize: SizeRecord) throws {
        if let existing = try fetch(barcode: product.id) {
            existing.lastKnownSize = currentSize.quantity
            existing.lastKnownUnit = currentSize.unit
            existing.lastChecked = Date()
            return
        }
        let watched = WatchedProduct.from(product: product, currentSize: currentSize)
        context.insert(watched)
        try context.save()
    }

    func remove(_ watched: WatchedProduct) throws {
        context.delete(watched)
        try context.save()
    }

    func setAlertEnabled(_ enabled: Bool, for watched: WatchedProduct) throws {
        watched.alertEnabled = enabled
        try context.save()
    }

    func fetch(barcode: String) throws -> WatchedProduct? {
        var descriptor = FetchDescriptor<WatchedProduct>(
            predicate: #Predicate { $0.barcode == barcode }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func all() throws -> [WatchedProduct] {
        let descriptor = FetchDescriptor<WatchedProduct>(
            sortBy: [SortDescriptor(\.addedAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    // MARK: - Background sweep

    /// Iterates watched products, hits OFF, detects shrink. Returns the
    /// records that newly shrunk so `NotificationScheduler` can fire alerts.
    func refreshAll() async -> [(WatchedProduct, ShrinkRecord)] {
        let watched: [WatchedProduct]
        do {
            watched = try all()
        } catch {
            return []
        }

        var results: [(WatchedProduct, ShrinkRecord)] = []
        for item in watched where item.alertEnabled {
            do {
                let product = try await off.fetchProduct(barcode: item.barcode)
                let record = detector.analyze(product: product)
                let prevSize = item.lastKnownSize
                if let curr = record.currentSize,
                   abs(curr.quantity - prevSize) > 0.01 {
                    results.append((item, record))
                    item.lastKnownSize = curr.quantity
                    item.lastKnownUnit = curr.unit
                }
                item.lastChecked = Date()
            } catch {
                // Skip this product on transient failure — try again next sweep.
                continue
            }
            try? context.save()

            // Throttle to respect OFF rate limits (shared infrastructure).
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return results
    }
}
