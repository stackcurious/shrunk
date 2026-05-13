import Foundation

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
    @Published var alternatives: [Alternative] = []
    @Published var isLoadingAlternatives: Bool = false

    private let off: OpenFoodFactsService
    private let upc: UPCItemDBService
    private let engine: AlternativesEngine
    private let detector: ShrinkDetector

    init(
        off: OpenFoodFactsService = .shared,
        upc: UPCItemDBService = .shared,
        engine: AlternativesEngine = AlternativesEngine(),
        detector: ShrinkDetector = ShrinkDetector()
    ) {
        self.off = off
        self.upc = upc
        self.engine = engine
        self.detector = detector
    }

    /// Inject a known product+record (e.g. for curated Browse cards) so the
    /// view skips the product round-trip and lands directly in `.loaded`.
    /// Kicks off the alternatives fetch in the background so the sheet doesn't
    /// open with a stale empty section.
    func prebake(product: ShrunkProduct, record: ShrinkRecord) {
        state = .loaded(product, record)
        alternatives = []
        Task { await loadAlternatives(for: product, record: record) }
    }

    func load(barcode: String) async {
        if case .loaded = state { return }   // already prebaked — don't clobber
        state = .loading
        alternatives = []

        do {
            let product = try await off.fetchProduct(barcode: barcode)
            let record = detector.analyze(product: product)
            state = .loaded(product, record)
            await loadAlternatives(for: product, record: record)
            return
        } catch ShrunkError.productNotFound {
            await loadFromFallback(barcode: barcode)
            return
        } catch let error as ShrunkError {
            state = .error(error.errorDescription ?? "Something went wrong.")
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func loadFromFallback(barcode: String) async {
        do {
            let product = try await upc.fetchProduct(barcode: barcode)
            let record = detector.analyze(product: product)
            state = .loaded(product, record)
            await loadAlternatives(for: product, record: record)
        } catch ShrunkError.productNotFound {
            state = .notFound(barcode: barcode)
        } catch let error as ShrunkError {
            state = .error(error.errorDescription ?? "Something went wrong.")
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func loadAlternatives(for product: ShrunkProduct, record: ShrinkRecord) async {
        isLoadingAlternatives = true
        let results = await engine.findAlternatives(for: product, shrinkRecord: record)
        alternatives = results
        isLoadingAlternatives = false
    }
}
