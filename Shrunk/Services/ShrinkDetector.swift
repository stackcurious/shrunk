import Foundation

/// Compares historical sizes of a product to determine whether the manufacturer
/// has reduced the package quantity ("shrinkflation") and surfaces the
/// real cost-per-unit shift the customer is now paying.
///
/// Pure logic, no I/O — fed `ShrunkProduct` data assembled by services.
struct ShrinkDetector {

    /// - Parameter liveSize: the size parsed from the user's live store row,
    ///   used **only** when the product carries no observation of its own
    ///   (spec rule 5). A product found through the on-miss lookup comes back
    ///   with `observations: []`, so without this the Result screen would have
    ///   no size to show and the Watch button no baseline to watch. A stored
    ///   observation always wins — this is a stand-in for having none, never
    ///   an override.
    /// - Parameter livePrice: the effective shelf price at the user's live
    ///   store, used on the same terms: only when the product has no price of
    ///   its own. `ProductDTO.toProduct` sets `currentPrice` from the newest
    ///   `price_snapshots` row, so a fresh on-miss product has neither, and
    ///   without this the single-snapshot row keeps its size promise but
    ///   breaks its per-ounce one — the cost/oz card hides, the
    ///   cheapest-per-oz callout cannot render, and `AlternativesEngine` has
    ///   no `scannedCostPerOz` to say "N % cheaper" against. An adopted live
    ///   price is real store data, so it sets `priceIsFromStoreSnapshot` and
    ///   carries `LivePrice.attribution` with it.
    func analyze(
        product: ShrunkProduct,
        liveSize: SizeRecord? = nil,
        livePrice: Double? = nil
    ) -> ShrinkRecord {
        let stored = product.sizeHistory.sorted { $0.date < $1.date }
        let sorted: [SizeRecord] = {
            guard stored.isEmpty, let liveSize, liveSize.quantity > 0 else { return stored }
            return [liveSize]
        }()

        // Only compare records of the same kind as the most recent one —
        // grams vs fluid ounces must never produce a verdict.
        let sameKind: [SizeRecord] = {
            guard let latestKind = sorted.last?.unitKind else { return [] }
            return sorted.filter { $0.unitKind == latestKind }
        }()

        // The two most recent store snapshots, oldest first.
        let prices = product.priceHistory.sorted { $0.date < $1.date }
        let storedPriceNow = prices.last?.price ?? product.currentPrice
        // Spec rule 5, price half — adopted only into a gap, exactly like the
        // size above. A stored price always wins.
        let adoptedPrice: Double? = storedPriceNow == nil ? livePrice.flatMap { $0 > 0 ? $0 : nil } : nil
        let priceNow = storedPriceNow ?? adoptedPrice
        let priceThen = prices.count >= 2 ? prices[prices.count - 2].price : nil
        // True when priceNow came from a price_snapshots-backed PricePoint or
        // from the live store row — both are real store observations that may
        // (and must) carry Kroger attribution. False for the
        // product.currentPrice fallback used when there's no snapshot history
        // at all (e.g. curated Browse cards from trending.json), which is
        // editorial and must never be labelled Kroger.
        let priceIsFromStoreSnapshot = prices.last != nil || adoptedPrice != nil

        // Spec §5.1 — the verdict compares the last two *size runs*, not the
        // last two observations.
        let runs = Self.collapseRuns(sameKind)

        // Fewer than two comparable runs — no verdict is possible, but
        // the record still has to carry what we *do* know (spec §2): the one
        // size on file and what it costs per ounce. `previousSize` is
        // deliberately nil rather than a copy of the current record: there is
        // no "then", and reporting one made the Result screen draw a Then→Now
        // row comparing a size with itself.
        guard runs.count >= 2 else {
            // The size we know, dated from when we *first* saw it. `ResultView`
            // renders this state as "946 ml, first seen Feb 2018" — and a
            // second source confirming that same 946 ml in 2024 must not move
            // that year forward. (The Then→Now row, which wants each run's
            // latest date, only draws when there are two runs.)
            let current = sorted.last.map { latest in
                SizeRecord(
                    date: runs.first?.opened.date ?? latest.date,
                    quantity: latest.quantity,
                    unit: latest.unit,
                    source: latest.source
                )
            }
            return ShrinkRecord(
                product: product,
                previousSize: nil,
                currentSize: current,
                shrinkPercent: 0,
                priceThen: nil,
                priceNow: priceNow,
                costPerUnitThen: nil,
                costPerUnitNow: Self.costPerUnit(price: priceNow, size: current),
                priceIsFromStoreSnapshot: priceIsFromStoreSnapshot,
                verdict: .insufficientData
            )
        }

        let currentRun  = runs[runs.count - 1]
        let previousRun = runs[runs.count - 2]
        // Reported ends of the comparison: the run's quantity/unit/source (its
        // first observation, per spec §5.1) carrying the run's *latest* date,
        // so a "Then 2019 → Now 2022" row still names the years the shopper
        // would recognise rather than the first day each size was recorded.
        let previousSize = previousRun.reported
        let currentSize  = currentRun.reported
        let current  = Self.normalize(currentSize)
        let previous = Self.normalize(previousSize)

        // Guard against zero-quantity records that would explode the percentage math.
        guard previous.quantity > 0 else {
            return ShrinkRecord(
                product: product,
                previousSize: previousSize,
                currentSize: currentSize,
                shrinkPercent: 0,
                priceThen: priceThen,
                priceNow: priceNow,
                costPerUnitThen: nil,
                costPerUnitNow: priceNow.map { $0 / max(current.quantity, 0.0001) },
                priceIsFromStoreSnapshot: priceIsFromStoreSnapshot,
                verdict: .insufficientData
            )
        }

        // C2 plausibility clamp: a same-kind pair from two *different* sources
        // whose implied ratio is outside a sane single-step range is far more
        // likely a unit-parsing mismatch between sources (e.g. a multipack
        // total from one source vs. a per-unit size from another) than a real
        // shrink/growth — render `.insufficientData` rather than a confident,
        // wrong verdict. Same-source pairs are never clamped: a real shrink
        // reported twice by one source is exactly the case this app exists to
        // catch, however large. Now applied to the *run* pair: each run's
        // source is the one that opened it, the same observation its quantity
        // comes from.
        if previous.source != current.source {
            let ratio = current.quantity / previous.quantity
            guard ratio <= 4 && ratio >= 0.25 else {
                return ShrinkRecord(
                    product: product,
                    previousSize: previousSize,
                    currentSize: currentSize,
                    shrinkPercent: 0,
                    priceThen: priceThen,
                    priceNow: priceNow,
                    costPerUnitThen: nil,
                    costPerUnitNow: current.quantity > 0 ? priceNow.map { $0 / current.quantity } : nil,
                    priceIsFromStoreSnapshot: priceIsFromStoreSnapshot,
                    verdict: .insufficientData
                )
            }
        }

        let percentChange = ((current.quantity - previous.quantity) / previous.quantity) * 100

        // "Now" is today's price over today's size; "then" is the older snapshot
        // over the older size — the cost this shopper used to pay. `previous`
        // is already guarded > 0 above; `current` needs its own guard so a
        // zero-quantity size record can't divide a real price into `inf`.
        let costPerUnitNow: Double? = current.quantity > 0 ? priceNow.map { $0 / current.quantity } : nil
        let costPerUnitThen: Double? = priceThen.map { $0 / previous.quantity }

        // `.unchanged` is unreachable from here since size runs landed:
        // adjacent runs differ by more than `sameSizeTolerance` by
        // construction, so `percentChange` is always outside ±1%. The band is
        // kept as the boundary it always was — the enum case is still what
        // `WatchedProduct` and the alert models carry for a size that held.
        let verdict: ShrinkRecord.ShrinkVerdict = {
            switch percentChange {
            case ..<(-10):    return .significantShrink
            case -10 ..< -5:  return .moderateShrink
            case -5  ..< -1:  return .minorShrink
            case -1 ..< 1:    return .unchanged
            default:          return .grew
            }
        }()

        return ShrinkRecord(
            product: product,
            previousSize: previousSize,
            currentSize: currentSize,
            shrinkPercent: percentChange,
            priceThen: priceThen,
            priceNow: priceNow,
            costPerUnitThen: costPerUnitThen,
            costPerUnitNow: costPerUnitNow,
            priceIsFromStoreSnapshot: priceIsFromStoreSnapshot,
            verdict: verdict
        )
    }

    // MARK: - Size runs (spec §5.1)

    /// Spec §5.1 — two observations that normalize within 1% are the same size.
    static let sameSizeTolerance = 0.01

    /// A stretch of consecutive same-kind observations that all report the same
    /// size. The run's *quantity* is the value that opened it; its `sources` is
    /// the union of every source that reported it.
    struct SizeRun {
        /// The observation that opened the run — quantity, unit and source.
        let opened: SizeRecord
        /// The run's most recent observation. Only its `date` is reported.
        fileprivate(set) var latest: SizeRecord
        fileprivate(set) var sources: [String]
        /// `opened`'s size carrying `latest`'s date (spec §5.1).
        var reported: SizeRecord {
            SizeRecord(date: latest.date, quantity: opened.quantity, unit: opened.unit, source: opened.source)
        }
    }

    /// Collapses same-kind observations, oldest first, into size runs.
    ///
    /// Without this a *confirmation* read as a *change of nothing*: when a
    /// second source reports exactly the size the last observation already
    /// recorded, the last-two-observations pair is `450 → 450`, `+0.0 %`,
    /// "Unchanged" — erasing the documented `500 → 450` behind it. Eight of the
    /// 25 verified curated cases scored "no shrink" that way, Fage most
    /// starkly: USDA confirms *both* of its endpoints and the product still
    /// read as never having shrunk.
    ///
    /// Each observation is compared against the quantity that *opened* the
    /// current run rather than against its immediate predecessor, so a slow
    /// drift of within-tolerance steps can never accumulate into one run that
    /// spans a real change.
    static func collapseRuns(_ records: [SizeRecord]) -> [SizeRun] {
        var runs: [SizeRun] = []
        for record in records {
            let quantity = normalize(record).quantity
            if var run = runs.last, isSameSize(normalize(run.opened).quantity, quantity) {
                run.latest = record
                if !run.sources.contains(record.source) { run.sources.append(record.source) }
                runs[runs.count - 1] = run
            } else {
                runs.append(SizeRun(opened: record, latest: record, sources: [record.source]))
            }
        }
        return runs
    }

    /// Within `sameSizeTolerance` of `reference`. A zero (or negative)
    /// reference has no meaningful percentage, so only an exact match counts —
    /// which keeps a `0 → 28` history two runs rather than one.
    private static func isSameSize(_ reference: Double, _ quantity: Double) -> Bool {
        guard reference > 0 else { return quantity == reference }
        return abs(quantity - reference) / reference <= sameSizeTolerance
    }

    /// `price ÷ normalized quantity` for one size record — the per-ounce number
    /// the single-snapshot screen leads with. `nil` when either half is missing
    /// or the size normalizes to zero (which would divide a real price into
    /// `inf`).
    private static func costPerUnit(price: Double?, size: SizeRecord?) -> Double? {
        guard let price, let size else { return nil }
        let normalized = normalize(size).quantity
        guard normalized > 0 else { return nil }
        return price / normalized
    }

    /// Convert any unit to fluid-ounce-equivalent so percentage comparison is unit-stable.
    /// "count" items pass through unchanged (comparing 12-pack vs 10-pack is already meaningful).
    static func normalize(_ record: SizeRecord) -> SizeRecord {
        let q = record.quantity
        let normalizedQuantity: Double
        switch record.unit.lowercased() {
        case "g":           normalizedQuantity = q * 0.035274
        case "kg":          normalizedQuantity = q * 35.274
        case "ml":          normalizedQuantity = q * 0.033814
        case "l":           normalizedQuantity = q * 33.814
        case "oz", "fl oz": normalizedQuantity = q
        default:            normalizedQuantity = q
        }
        return SizeRecord(
            date: record.date,
            quantity: normalizedQuantity,
            unit: "oz",
            source: record.source
        )
    }

    /// The oz-equivalent unit price for a Kroger-shaped quantity (grams |
    /// millilitres | count) and price, routed through the same `normalize`
    /// space `analyze` uses for `costPerUnitNow` — so the live panel, the
    /// alternatives ranking, and the verdict all agree on one number.
    /// (Phase 3 review M2/T17 — was duplicated in `LivePricePanel` and
    /// `AlternativesEngine`; both now delegate here.)
    static func costPerOunce(price: Double?, quantity: Double?, unitKind: String?) -> Double? {
        guard let price, let quantity, quantity > 0, let unitKind else { return nil }
        let unit: String
        switch unitKind {
        case "mass":   unit = "g"
        case "volume": unit = "ml"
        default:       unit = "count"
        }
        let normalized = normalize(
            SizeRecord(date: Date(), quantity: quantity, unit: unit, source: "kroger")
        ).quantity
        guard normalized > 0 else { return nil }
        return price / normalized
    }
}
