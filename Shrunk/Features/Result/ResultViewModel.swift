import Foundation

/// What the result screen shows for the user's store.
enum LivePriceState: Equatable {
    case hidden          // no store set — the panel is not shown at all
    case loading
    case loaded(LivePrice)
    case unavailable     // Kroger down, key revoked, or not carried here
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
        alternativesResult = .empty
        Task {
            await loadLivePrice(barcode: product.id)
            await loadAlternatives(for: product, record: record)
        }
    }

    func load(barcode: String) async {
        if case .loaded = state { return }   // already prebaked — don't clobber
        state = .loading
        alternativesResult = .empty
        livePrice = locationId == nil ? .hidden : .loading
        liveSizeMismatch = false

        do {
            let product = try await api.fetchProduct(barcode: barcode, locationId: locationId)
            let record = detector.analyze(product: product)
            state = .loaded(product, record)
            await loadLivePrice(barcode: barcode)
            await loadAlternatives(for: product, record: record)
        } catch ShrunkError.productNotFound {
            state = .notFound(barcode: barcode)
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
            if case .loaded(let product, _) = state {
                liveSizeMismatch = Self.detectSizeMismatch(live: live, sizeHistory: product.sizeHistory)
            }
        } catch {
            livePrice = .unavailable
        }
    }

    /// Compares the live Kroger size against the newest **non-Kroger**
    /// observation (spec §4 step 4). Ignoring `source == "kroger"` records is
    /// what keeps this correct across repeated scans — a stale live fetch
    /// should never be judged against a size Kroger itself supplied earlier.
    private static func detectSizeMismatch(live: LivePrice, sizeHistory: [SizeRecord]) -> Bool {
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

        guard let latest = sizeHistory
            .filter({ $0.source != "kroger" })
            .sorted(by: { $0.date < $1.date })
            .last,
            latest.unitKind == kind
        else { return false }

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
