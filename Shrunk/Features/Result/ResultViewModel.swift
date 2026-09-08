import Foundation

/// What the result screen shows for the user's store.
enum LivePriceState: Equatable {
    case hidden          // no store set — the panel is not shown at all
    case loading
    case loaded(LivePrice)
    case unavailable     // Kroger down, key revoked, or not carried here
}

/// Process-lifetime cache of the last successfully loaded product per barcode
/// (spec §8: "Backend unreachable: app shows cached last result for known
/// products, otherwise 'Couldn't reach Shrunk — check connection.'"). A plain
/// instance property on `ResultViewModel` would not survive this — the view
/// model is recreated per screen presentation (`.task(id: barcode)` in
/// `ResultView`) — so a static, `@MainActor`-isolated dictionary is the
/// simplest thing that does. Deliberately in-memory only, not persisted to
/// disk: it only needs to outlive the view, not the process, so this stays a
/// small fix. `internal` (not `private`) so tests can reset it between runs.
@MainActor
enum ProductResultCache {
    static var products: [String: ShrunkProduct] = [:]
}

@MainActor
final class ResultViewModel: ObservableObject {
    enum State: Equatable {
        case loading
        case loaded(ShrunkProduct, ShrinkRecord)
        case notFound(barcode: String)
        case error(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.loading, .loading): return true
            case (.loaded(let a, _), .loaded(let b, _)): return a.id == b.id
            case (.notFound(let a), .notFound(let b)): return a == b
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }

    /// What the Result screen's Watch button must do when tapped (spec §2).
    /// Pure and exhaustive so no tap can fall through to nothing — the bug
    /// this replaces was two `guard … else { return }`s that silently swallowed
    /// the tap on any product with no size (spec §0).
    enum WatchOutcome: Equatable {
        /// Already on the watchlist — the button starts in its watched state
        /// rather than forgetting across re-opens.
        case alreadyWatched
        /// No size on record, so there is nothing to watch yet: the button
        /// becomes the label-capture CTA.
        case needsLabel
        /// Watching is a Pro feature.
        case paywall
        /// Add it, with a toast and a success haptic.
        case watch
    }

    /// What to do with a Watch tap that opened the Pro paywall. Keeping this
    /// decision pure prevents an entitlement refresh from either losing the
    /// user's tap or adding a product they never asked to watch.
    enum PendingWatchResolution: Equatable {
        case wait
        case add
        case clear
    }

    /// Precedence, deliberately:
    ///
    /// 1. `alreadyWatched` — a truthful "On your watchlist" beats both
    ///    re-selling Pro and re-adding a row that already exists.
    /// 2. `needsLabel` — checked **before** the paywall. Watching a product
    ///    with zero observations is impossible at any price (rule 3), so
    ///    paywalling it would leave a free user on the fresh-lookup screen
    ///    with no action at all, violating rule 1 ("a scan never dead-ends").
    ///    Label capture is not a Pro feature and is the step that unblocks
    ///    watching, so it wins.
    /// 3. `paywall` — a watchable product, but not a paying user.
    static func watchOutcome(record: ShrinkRecord, isPro: Bool, isAlreadyWatched: Bool) -> WatchOutcome {
        if isAlreadyWatched { return .alreadyWatched }
        if record.currentSize == nil { return .needsLabel }
        if !isPro { return .paywall }
        return .watch
    }

    static func resolvePendingWatch(
        isPending: Bool,
        isPro: Bool,
        isAlreadyWatched: Bool
    ) -> PendingWatchResolution {
        guard isPending else { return .clear }
        if isAlreadyWatched { return .clear }
        return isPro ? .add : .wait
    }

    @Published var state: State = .loading
    @Published var alternativesResult: AlternativesResult = .empty
    @Published var isLoadingAlternatives: Bool = false
    @Published var livePrice: LivePriceState = .hidden
    /// Client-side counterpart to `product.needsConfirmation` (spec §4 step 4,
    /// Phase 3 review I5). The server only sets `needsConfirmation` from a
    /// *stored* `kroger` observation, so it's one scan late and dead when
    /// `KROGER_PERSIST=off` never writes one. This is computed the moment the
    /// live fetch returns and is OR'd with the server flag at the read site.
    @Published var liveSizeMismatch: Bool = false
    /// True when `currentSize` came from the live store row rather than one of
    /// our own observations (spec rule 5). Only the screen's wording depends on
    /// it — "‹size› at Kroger today" instead of "first seen ‹Mon YYYY›".
    @Published var adoptedLiveSize: Bool = false

    private let api: ShrunkAPIClient
    private let engine: AlternativesEngine
    private let detector: ShrinkDetector
    private let defaults: UserDefaults

    /// The store the user picked, if any (spec §7).
    private var locationId: String? {
        let saved = defaults.string(forKey: StorePickerViewModel.locationIdKey)
        return (saved?.isEmpty ?? true) ? nil : saved
    }

    /// Set by the view from `StoreKitService.isProUser` before loading.
    var isPro: Bool = false

    init(
        api: ShrunkAPIClient = .shared,
        engine: AlternativesEngine = AlternativesEngine(),
        detector: ShrinkDetector = ShrinkDetector(),
        defaults: UserDefaults = .standard
    ) {
        self.api = api
        self.engine = engine
        self.detector = detector
        self.defaults = defaults
    }

    /// Inject a known product+record (e.g. for curated Browse cards) so the
    /// view skips the product round-trip and lands directly in `.loaded`.
    /// Kicks off the alternatives fetch in the background so the sheet doesn't
    /// open with a stale empty section.
    func prebake(product: ShrunkProduct, record: ShrinkRecord) {
        state = .loaded(product, record)
        ProductResultCache.products[product.id] = product
        alternativesResult = .empty
        adoptedLiveSize = false
        Task {
            await loadLivePrice(barcode: product.id)
            await loadAlternatives(for: product, record: currentRecord ?? record)
        }
    }

    /// The record currently in `state`, if any.
    private var currentRecord: ShrinkRecord? {
        if case .loaded(_, let record) = state { return record }
        return nil
    }

    func load(barcode: String) async {
        if case .loaded = state { return }   // already prebaked — don't clobber
        state = .loading
        alternativesResult = .empty
        livePrice = locationId == nil ? .hidden : .loading
        liveSizeMismatch = false
        adoptedLiveSize = false

        do {
            let product = try await api.fetchProduct(barcode: barcode, locationId: locationId)
            ProductResultCache.products[barcode] = product
            let record = detector.analyze(product: product)
            state = .loaded(product, record)
            await loadLivePrice(barcode: barcode)
            // Re-read: `loadLivePrice` may have adopted the live size, and the
            // alternatives search needs that record's `unitKind` to rank
            // like with like — without it a fresh lookup gets no store rows.
            await loadAlternatives(for: product, record: currentRecord ?? record)
        } catch ShrunkError.productNotFound {
            state = .notFound(barcode: barcode)
            livePrice = .hidden
        } catch ShrunkError.network(let underlying) {
            // Spec §8: a known product (one we've already shown successfully
            // this run) still renders offline from cache; only an unknown one
            // falls back to the verbatim copy.
            if let cached = ProductResultCache.products[barcode] {
                state = .loaded(cached, detector.analyze(product: cached))
            } else {
                state = .error(ShrunkError.network(underlying).errorDescription ?? "Couldn't reach Shrunk — check connection.")
            }
            livePrice = .hidden
        } catch let error as ShrunkError {
            state = .error(error.errorDescription ?? "Something went wrong.")
            livePrice = .hidden
        } catch {
            state = .error(error.localizedDescription)
            livePrice = .hidden
        }
    }

    /// Live price is strictly additive — a Kroger failure never changes `state`
    /// (spec §8).
    private func loadLivePrice(barcode: String) async {
        guard let locationId else {
            livePrice = .hidden
            return
        }
        livePrice = .loading
        do {
            let live = try await api.liveProduct(barcode: barcode, locationId: locationId)
            livePrice = .loaded(live)
            if case .loaded(let product, let record) = state {
                liveSizeMismatch = Self.detectSizeMismatch(live: live, sizeHistory: product.sizeHistory)
                // Re-run when the live row can improve either half of the
                // result. Stored observations still win for size, while a valid
                // live price is authoritative for today's cost-per-unit. That
                // prevents a cached snapshot or bundled editorial price from
                // disagreeing with the live-price panel and alternatives.
                if record.currentSize == nil || live.effectivePrice != nil {
                    let analyzed = detector.analyze(
                        product: product,
                        liveSize: Self.sizeRecord(from: live),
                        livePrice: live.effectivePrice
                    )
                    let adopted = liveSizeMismatch
                        ? Self.withholdingUnitPricing(from: analyzed)
                        : analyzed
                    adoptedLiveSize = record.currentSize == nil && adopted.currentSize != nil
                    state = .loaded(product, adopted)
                }
            }
        } catch {
            livePrice = .unavailable
        }
    }

    /// A live price cannot be divided by a conflicting documented size. Keep
    /// the size verdict, but withhold all price-derived claims until the label
    /// photo confirms which package is on shelf.
    static func withholdingUnitPricing(from record: ShrinkRecord) -> ShrinkRecord {
        ShrinkRecord(
            product: record.product,
            previousSize: record.previousSize,
            currentSize: record.currentSize,
            shrinkPercent: record.shrinkPercent,
            priceThen: nil,
            priceNow: nil,
            costPerUnitThen: nil,
            costPerUnitNow: nil,
            priceIsFromStoreSnapshot: false,
            verdict: record.verdict
        )
    }

    /// The live store row as a `SizeRecord`, or nil when it carries no usable
    /// size. The provider's own `source` is carried through, so the adopted
    /// observation is attributed to whoever actually reported it rather than
    /// to a hard-coded "kroger".
    static func sizeRecord(from live: LivePrice) -> SizeRecord? {
        guard let quantity = live.quantity, quantity > 0, let kind = live.unitKind else { return nil }
        return SizeRecord(
            date: Date(),
            quantity: quantity,
            unit: ProductDTO.unit(forKind: kind),
            source: live.source
        )
    }

    /// Compares the live package size with the newest stored size — the exact
    /// denominator the detector would otherwise use with today's live price.
    /// A unit-kind conflict is itself a mismatch and must withhold derived
    /// pricing until a label confirms which package is on shelf.
    static func detectSizeMismatch(live: LivePrice, sizeHistory: [SizeRecord]) -> Bool {
        guard let quantity = live.quantity, let kind = live.unitKind, quantity > 0 else { return false }
        let unit: String
        switch kind {
        case "mass":   unit = "g"
        case "volume": unit = "ml"
        default:       unit = "count"
        }
        let liveNormalized = ShrinkDetector.normalize(
            SizeRecord(date: Date(), quantity: quantity, unit: unit, source: "kroger")
        ).quantity
        guard liveNormalized > 0 else { return false }

        guard let latest = sizeHistory.sorted(by: { $0.date < $1.date }).last else {
            return false
        }
        guard latest.unitKind == kind else { return true }

        let latestNormalized = ShrinkDetector.normalize(latest).quantity
        guard latestNormalized > 0 else { return false }

        return abs(liveNormalized - latestNormalized) / latestNormalized > 0.01
    }

    /// Force a fresh fetch. `load` deliberately no-ops on an already-loaded
    /// state, so a crowd contribution needs this to surface its new observation.
    func reload(barcode: String) async {
        state = .loading
        await load(barcode: barcode)
    }

    private func loadAlternatives(for product: ShrunkProduct, record: ShrinkRecord) async {
        isLoadingAlternatives = true
        alternativesResult = await engine.findAlternatives(
            for: product,
            shrinkRecord: record,
            locationId: locationId,
            isPro: isPro
        )
        isLoadingAlternatives = false
    }

    /// Minor #4: `isPro` is otherwise captured once, in `.task(id: barcode)`,
    /// so a user who upgrades from the history chart's in-screen upgrade row
    /// would keep seeing the free 3-item cap until the result reloads. Called
    /// from the view's `.onChange(of: storeKit.isProUser)`; re-runs the
    /// alternatives fetch so the cap lifts (or, on a downgrade, re-applies)
    /// without a reload. A no-op if nothing has actually changed or nothing
    /// has loaded yet.
    func refreshAlternatives(isPro: Bool) async {
        guard self.isPro != isPro else { return }
        self.isPro = isPro
        guard case .loaded(let product, let record) = state else { return }
        await loadAlternatives(for: product, record: record)
    }
}
