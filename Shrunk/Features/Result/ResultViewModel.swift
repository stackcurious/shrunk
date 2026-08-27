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
            livePrice = .loaded(try await api.liveProduct(barcode: barcode, locationId: locationId))
        } catch {
            livePrice = .unavailable
        }
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
}
