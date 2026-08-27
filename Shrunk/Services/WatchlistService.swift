import Foundation
import SwiftData

/// Why a watchlist write could not happen.
///
/// `add` used to `return` silently when the record had no current size, which
/// is exactly what made "Watch this product" a dead button on TestFlight
/// build 2 (spec §0): no row written, no error, no feedback. Spec rule 4 —
/// "no silent `return`s on user actions" — so the caller now gets something it
/// can put in a toast.
enum WatchlistError: LocalizedError, Equatable {
    /// The product has no observation and no adopted live size, so there is no
    /// baseline for a `size_drop` alert to compare against. The screen's answer
    /// is to send the user to label capture, not to fail quietly.
    case noSizeToWatch

    var errorDescription: String? {
        switch self {
        case .noSizeToWatch:
            return "We need this product's size first — snap the label to start tracking it."
        }
    }
}

/// Wraps the SwiftData ModelContext for watched-product CRUD, keeps the
/// Worker's copy of the watch list current (spec §7), and runs the device-side
/// live-size check that `BGAppRefresh` wakes us for. The view layer uses
/// `@Query` directly for live fetches; this service handles writes.
@MainActor
final class WatchlistService {
    private let context: ModelContext
    private let store: StoreDataProviding
    private let sync: WatchlistSyncing

    init(
        context: ModelContext,
        store: StoreDataProviding = ShrunkAPIClient.shared,
        sync: WatchlistSyncing = ShrunkAPIClient.shared
    ) {
        self.context = context
        self.store = store
        self.sync = sync
    }

    // MARK: - CRUD

    /// Files a watch. **One observation is enough** (spec rule 3) — it becomes
    /// the baseline a future `size_drop` alert compares against, which is the
    /// whole promise of the single-snapshot screen. Only a record with no size
    /// at all is refused, and it now says so.
    func add(product: ShrunkProduct, record: ShrinkRecord) throws {
        guard let currentSize = record.currentSize else { throw WatchlistError.noSizeToWatch }
        if let existing = try fetch(barcode: product.id) {
            existing.lastKnownSize = currentSize.quantity
            existing.lastKnownUnit = currentSize.unit
            // I5: only a store-observed price may overwrite a previously
            // good one — a curated re-add (editorial trending.json price)
            // must not clobber it with a non-observed figure.
            if record.priceIsFromStoreSnapshot {
                existing.lastKnownPrice = record.priceNow
            }
            existing.lastShrinkPercent = record.shrinkPercent
            existing.lastChecked = Date()
            try context.save()
            scheduleSync()
            return
        }
        let watched = WatchedProduct.from(product: product, record: record)
        context.insert(watched)
        try context.save()
        scheduleSync()
    }

    /// Files a `.newShrink` alert for a confirmed shrink found on a plain
    /// scan (spec §3.5 — "for each scanned or watched product"), independent
    /// of whether the product is on the watchlist. Silently does nothing for
    /// a non-shrink verdict or a record with no current size. Dedupes on
    /// (barcode, currentQuantity) so re-scanning the same size doesn't
    /// refile — see `ShrinkAlert.newShrink(from product:record:)` for why the
    /// alert itself is filed already read.
    func recordScannedShrink(product: ShrunkProduct, record: ShrinkRecord) throws {
        guard record.verdict.isShrink, let currentQuantity = record.currentSize?.quantity else { return }
        guard !(try alreadyFiledNewShrinkAlert(barcode: product.id, currentQuantity: currentQuantity)) else { return }
        context.insert(ShrinkAlert.newShrink(from: product, record: record))
        try context.save()
    }

    func remove(_ watched: WatchedProduct) throws {
        context.delete(watched)
        try context.save()
        scheduleSync()
    }

    func setAlertEnabled(_ enabled: Bool, for watched: WatchedProduct) throws {
        watched.alertEnabled = enabled
        try context.save()
        scheduleSync()
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

    // MARK: - Backend sync

    /// Fire and forget — the UI never waits on the network (spec §8). A local
    /// CRUD change always syncs, even to push an emptied list.
    private func scheduleSync() {
        Task { await syncToBackend(force: true) }
    }

    /// Posts the whole watch list to `/v1/devices`; the Worker replaces its
    /// copy wholesale (spec §6.1). Never throws.
    ///
    /// Periodic/foreground callers (`ShrunkApp`'s scenePhase and BGAppRefresh
    /// paths) leave `force` at its default and skip the network call when the
    /// list is empty — there's nothing new for the Worker to learn. A caller
    /// that just changed the list (add/remove/toggle, via `scheduleSync`)
    /// passes `force: true` so removing the last watch still tells the Worker
    /// to clear its copy.
    func syncToBackend(force: Bool = false) async {
        let payload: [DeviceWatch]
        do {
            payload = try all().map {
                DeviceWatch(gtin: $0.barcode, brand: $0.brand, alertEnabled: $0.alertEnabled)
            }
        } catch {
            return
        }
        guard force || !payload.isEmpty else { return }
        await sync.syncDevice(
            deviceId: DeviceIdentity.current,
            transactionJWS: "",
            apnsToken: nil,
            locationId: nil,
            categories: nil,
            watches: payload
        )
    }

    // MARK: - Device-side live-size check

    /// Spec §7 — `BGAppRefresh` compares the live size at the user's store with
    /// the last size we recorded. A mismatch is a hint, not an observation, so
    /// it files an `.unconfirmed` alert asking for a re-scan and leaves
    /// `lastKnownSize` alone. Returns the mismatches it filed.
    @discardableResult
    func liveSizeCheck() async -> [(WatchedProduct, Double)] {
        let locationId = UserDefaults.standard.string(forKey: "storeLocationId") ?? ""
        guard !locationId.isEmpty else { return [] }

        let watched: [WatchedProduct]
        do {
            watched = try all()
        } catch {
            return []
        }

        var mismatches: [(WatchedProduct, Double)] = []
        for item in watched where item.alertEnabled {
            guard let live = try? await store.liveProduct(barcode: item.barcode, locationId: locationId),
                  let quantity = live.quantity, quantity > 0,
                  let unitKind = live.unitKind,
                  ProductDTO.unit(forKind: unitKind) == item.lastKnownUnit,
                  item.lastKnownSize > 0
            else { continue }

            item.lastChecked = Date()
            // The live size may be an unconfirmed hint, but the live price is a
            // real observation either way — keep the savings dashboard's input
            // fresh even when the size itself doesn't need a re-scan.
            item.lastKnownPrice = live.effectivePrice ?? item.lastKnownPrice
            guard abs(quantity - item.lastKnownSize) / item.lastKnownSize > 0.01 else { continue }

            let alreadyFiled = (try? alreadyFiledUnconfirmedAlert(barcode: item.barcode, liveQuantity: quantity)) ?? false
            guard !alreadyFiled else { continue }

            context.insert(ShrinkAlert.unconfirmed(from: item, liveQuantity: quantity))
            mismatches.append((item, quantity))
        }
        try? context.save()
        return mismatches
    }

    /// True when an `.unconfirmed` alert already sits in the feed for this
    /// barcode at this exact live quantity, so `liveSizeCheck()` doesn't
    /// re-file (and re-push) the same hint on every refresh. A live size that
    /// changes again is still new information and gets its own alert.
    private func alreadyFiledUnconfirmedAlert(barcode: String, liveQuantity: Double) throws -> Bool {
        let unconfirmedRaw = ShrinkAlert.Kind.unconfirmed.rawValue
        let descriptor = FetchDescriptor<ShrinkAlert>(
            predicate: #Predicate { $0.barcode == barcode && $0.kindRaw == unconfirmedRaw }
        )
        return try context.fetch(descriptor).contains { $0.currentQuantity == liveQuantity }
    }

    /// True when a `.newShrink` alert already sits in the feed for this
    /// barcode at this exact size, so `recordScannedShrink` doesn't refile on
    /// every re-scan of an unchanged product.
    private func alreadyFiledNewShrinkAlert(barcode: String, currentQuantity: Double) throws -> Bool {
        let newShrinkRaw = ShrinkAlert.Kind.newShrink.rawValue
        let descriptor = FetchDescriptor<ShrinkAlert>(
            predicate: #Predicate { $0.barcode == barcode && $0.kindRaw == newShrinkRaw }
        )
        return try context.fetch(descriptor).contains { $0.currentQuantity == currentQuantity }
    }
}
