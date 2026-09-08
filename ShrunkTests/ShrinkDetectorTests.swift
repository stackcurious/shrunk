import XCTest
@testable import Shrunk

final class ShrinkDetectorTests: XCTestCase {

    private let detector = ShrinkDetector()

    // MARK: - Verdict thresholds

    func test_significantShrink_overTenPercent() {
        let product = makeProduct(history: [
            .init(quantity: 32, unit: "oz"),
            .init(quantity: 28, unit: "oz")
        ])
        let record = detector.analyze(product: product)
        XCTAssertEqual(record.verdict, .significantShrink)
        XCTAssertEqual(record.shrinkPercent, -12.5, accuracy: 0.01)
    }

    func test_moderateShrink_betweenFiveAndTen() {
        let product = makeProduct(history: [
            .init(quantity: 32, unit: "oz"),
            .init(quantity: 30, unit: "oz")  // -6.25%
        ])
        let record = detector.analyze(product: product)
        XCTAssertEqual(record.verdict, .moderateShrink)
    }

    func test_minorShrink_betweenOneAndFive() {
        let product = makeProduct(history: [
            .init(quantity: 100, unit: "g"),
            .init(quantity: 97, unit: "g")  // -3%
        ])
        let record = detector.analyze(product: product)
        XCTAssertEqual(record.verdict, .minorShrink)
    }

    func test_withinOnePercent_isOneRunAndSoInsufficientData() {
        // Spec §5.1: two observations that normalize within 1% are the *same
        // size*, so they collapse into a single run — and a single run has no
        // "then" to compare against. This used to report `.unchanged`, which
        // claimed a tracked-over-time verdict from what is really one
        // measurement seen twice.
        let product = makeProduct(history: [
            .init(quantity: 1000, unit: "ml"),
            .init(quantity: 999, unit: "ml")  // -0.1%
        ])
        let record = detector.analyze(product: product)
        XCTAssertEqual(record.verdict, .insufficientData)
        XCTAssertNil(record.previousSize)
        XCTAssertEqual(record.currentSize?.quantity, 1000, "the opening observation supplies the dated baseline")
    }

    func test_grew_whenSizeIncreasedAboveOnePercent() {
        let product = makeProduct(history: [
            .init(quantity: 100, unit: "g"),
            .init(quantity: 110, unit: "g")  // +10%
        ])
        let record = detector.analyze(product: product)
        XCTAssertEqual(record.verdict, .grew)
        XCTAssertGreaterThan(record.shrinkPercent, 0)
    }

    func test_insufficientData_oneRecord() {
        let product = makeProduct(history: [.init(quantity: 28, unit: "oz")])
        let record = detector.analyze(product: product)
        XCTAssertEqual(record.verdict, .insufficientData)
    }

    func test_insufficientData_emptyHistory() {
        let product = makeProduct(history: [])
        let record = detector.analyze(product: product)
        XCTAssertEqual(record.verdict, .insufficientData)
    }

    // MARK: - Unit normalization

    func test_normalize_gramsToOunces() {
        let oz = ShrinkDetector.normalize(SizeRecord(date: Date(), quantity: 100, unit: "g", source: "x"))
        XCTAssertEqual(oz.quantity, 3.5274, accuracy: 0.01)
        XCTAssertEqual(oz.unit, "oz")
    }

    func test_normalize_litersToOunces() {
        let oz = ShrinkDetector.normalize(SizeRecord(date: Date(), quantity: 1, unit: "L", source: "x"))
        XCTAssertEqual(oz.quantity, 33.814, accuracy: 0.01)
    }

    func test_normalize_unknownUnit_passesThrough() {
        let same = ShrinkDetector.normalize(SizeRecord(date: Date(), quantity: 12, unit: "count", source: "x"))
        XCTAssertEqual(same.quantity, 12)
    }

    // MARK: - Cross-unit comparison

    func test_crossUnit_gramsThenOunces_calculatesShrink() {
        // Originally 1000g (≈ 35.27oz), now 28oz — that's a real shrink
        let product = makeProduct(history: [
            .init(quantity: 1000, unit: "g"),
            .init(quantity: 28,   unit: "oz")
        ])
        let record = detector.analyze(product: product)
        XCTAssertTrue(record.verdict.isShrink)
    }

    // MARK: - Unit kinds

    func test_unitKind_derivedFromUnit() {
        XCTAssertEqual(SizeRecord(date: Date(), quantity: 1, unit: "g", source: "x").unitKind, "mass")
        XCTAssertEqual(SizeRecord(date: Date(), quantity: 1, unit: "oz", source: "x").unitKind, "mass")
        XCTAssertEqual(SizeRecord(date: Date(), quantity: 1, unit: "fl oz", source: "x").unitKind, "volume")
        XCTAssertEqual(SizeRecord(date: Date(), quantity: 1, unit: "ml", source: "x").unitKind, "volume")
        XCTAssertEqual(SizeRecord(date: Date(), quantity: 1, unit: "count", source: "x").unitKind, "count")
        XCTAssertEqual(SizeRecord(date: Date(), quantity: 1, unit: "bananas", source: "x").unitKind, "unknown")
    }

    func test_mixedKinds_massThenVolume_isInsufficientData() {
        // 1000 g then 28 fl oz: different kinds must never be compared.
        let product = makeProduct(history: [
            .init(quantity: 1000, unit: "g"),
            .init(quantity: 28,   unit: "fl oz")
        ])
        let record = detector.analyze(product: product)
        XCTAssertEqual(record.verdict, .insufficientData)
    }

    func test_mixedKinds_usesMostRecentKindOnly() {
        // An old volume record is ignored; the two mass records give -10% -> moderate.
        let product = makeProduct(history: [
            .init(quantity: 28,   unit: "fl oz"),
            .init(quantity: 1000, unit: "g"),
            .init(quantity: 900,  unit: "g")
        ])
        let record = detector.analyze(product: product)
        XCTAssertEqual(record.verdict, .moderateShrink)
        XCTAssertEqual(record.shrinkPercent, -10, accuracy: 0.01)
        XCTAssertEqual(record.previousSize?.quantity, 1000)
    }

    // MARK: - Cost per unit

    func test_costPerUnit_calculatedFromCurrentPrice() {
        let product = ShrunkProduct(
            id: "test",
            name: "Test",
            brand: "Brand",
            category: "x",
            imageURL: nil,
            sizeHistory: [
                SizeRecord(date: Date(timeIntervalSinceNow: -86400),
                           quantity: 32, unit: "oz", source: "x"),
                SizeRecord(date: Date(),
                           quantity: 28, unit: "oz", source: "x")
            ],
            currentPrice: 1.89,
            currency: "USD"
        )
        let record = detector.analyze(product: product)
        XCTAssertEqual(record.costPerUnitNow ?? 0, 1.89 / 28, accuracy: 0.0001)
    }

    func test_costPerUnit_nilWhenNoPrice() {
        let product = makeProduct(history: [
            .init(quantity: 32, unit: "oz"),
            .init(quantity: 28, unit: "oz")
        ], price: nil)
        let record = detector.analyze(product: product)
        XCTAssertNil(record.costPerUnitNow)
    }

    // MARK: - Edge cases

    func test_zeroPreviousQuantity_returnsInsufficientData() {
        let product = makeProduct(history: [
            .init(quantity: 0,  unit: "oz"),
            .init(quantity: 28, unit: "oz")
        ])
        let record = detector.analyze(product: product)
        XCTAssertEqual(record.verdict, .insufficientData)
    }

    func test_zeroCurrentQuantity_costPerUnitNowIsNilNotInfinite() {
        // Mirrors test_zeroPreviousQuantity_returnsInsufficientData, but on the
        // *current* side of the main (non-early-return) branch — a size record
        // that later collapses to 0 must not divide a real price into `inf`
        // on the money screen (Phase 3 review T15).
        let product = makeProduct(history: [
            .init(quantity: 28, unit: "oz"),
            .init(quantity: 0,  unit: "oz")
        ], price: 1.89)
        let record = detector.analyze(product: product)
        XCTAssertNil(record.costPerUnitNow)
    }

    func test_historyOutOfOrder_isSorted() {
        let now    = Date()
        let before = now.addingTimeInterval(-86400 * 365)
        let after  = now.addingTimeInterval(86400)

        let product = ShrunkProduct(
            id: "test", name: "Test", brand: "", category: "", imageURL: nil,
            sizeHistory: [
                SizeRecord(date: after,  quantity: 28, unit: "oz", source: "x"),
                SizeRecord(date: before, quantity: 32, unit: "oz", source: "x"),
                SizeRecord(date: now,    quantity: 30, unit: "oz", source: "x")
            ],
            currentPrice: nil, currency: "USD"
        )
        let record = detector.analyze(product: product)
        // Sorted ascending → previous: 30oz (now), current: 28oz (after) → -6.67% shrink
        XCTAssertEqual(record.currentSize?.quantity, 28)
        XCTAssertEqual(record.previousSize?.quantity, 30)
    }

    // MARK: - Helpers

    fileprivate struct SizeInput {
        let quantity: Double
        let unit: String

        init(quantity: Double, unit: String) {
            self.quantity = quantity
            self.unit = unit
        }
    }

    fileprivate func makeProduct(history: [SizeInput], price: Double? = nil) -> ShrunkProduct {
        let now = Date()
        let records = history.enumerated().map { idx, input in
            SizeRecord(
                date: now.addingTimeInterval(TimeInterval(idx) * 86400),
                quantity: input.quantity,
                unit: input.unit,
                source: "test"
            )
        }
        return ShrunkProduct(
            id: "test",
            name: "Test product",
            brand: "Test brand",
            category: "test",
            imageURL: nil,
            sizeHistory: records,
            currentPrice: price,
            currency: "USD"
        )
    }

    // MARK: - Price history

    private func makePriced(sizes: [(Double, String)], prices: [(TimeInterval, Double)]) -> ShrunkProduct {
        let base = Date(timeIntervalSince1970: 1_600_000_000)
        let history = sizes.enumerated().map { idx, s in
            SizeRecord(date: base.addingTimeInterval(TimeInterval(idx) * 86_400),
                       quantity: s.0, unit: s.1, source: "test")
        }
        let points = prices.map { PricePoint(date: base.addingTimeInterval($0.0), price: $0.1, perUnitEstimate: nil) }
        return ShrunkProduct(
            id: "test", name: "Test", brand: "Brand", category: "Beverages",
            imageURL: nil, sizeHistory: history, currentPrice: points.last?.price, currency: "USD",
            needsConfirmation: false, priceHistory: points
        )
    }

    func test_priceHistory_fillsThenAndNow() {
        // 32oz at $1.79 became 28oz at $1.89.
        let product = makePriced(sizes: [(32, "oz"), (28, "oz")], prices: [(0, 1.79), (86_400, 1.89)])
        let record = detector.analyze(product: product)

        XCTAssertEqual(record.priceThen ?? 0, 1.79, accuracy: 0.0001)
        XCTAssertEqual(record.priceNow ?? 0, 1.89, accuracy: 0.0001)
        XCTAssertEqual(record.costPerUnitThen ?? 0, 1.79 / 32, accuracy: 0.0001)
        XCTAssertEqual(record.costPerUnitNow ?? 0, 1.89 / 28, accuracy: 0.0001)
    }

    func test_priceHistory_singleSnapshotHasNoThen() {
        let product = makePriced(sizes: [(32, "oz"), (28, "oz")], prices: [(86_400, 1.89)])
        let record = detector.analyze(product: product)

        XCTAssertNil(record.priceThen)
        XCTAssertNil(record.costPerUnitThen)
        XCTAssertEqual(record.costPerUnitNow ?? 0, 1.89 / 28, accuracy: 0.0001)
    }

    func test_priceHistory_unalignedHistoricalSnapshotHasNoThen() {
        let day: TimeInterval = 86_400
        // The older size was observed at t=0, but this snapshot is more than a
        // month later. It cannot support a claim about what the old size cost.
        let product = makePriced(
            sizes: [(32, "oz"), (28, "oz")],
            prices: [(31 * day, 1.79), (32 * day, 1.89)]
        )
        let record = detector.analyze(product: product)

        XCTAssertNil(record.priceThen)
        XCTAssertNil(record.costPerUnitThen)
        XCTAssertEqual(record.priceNow ?? 0, 1.89, accuracy: 0.0001)
    }

    func test_priceHistory_snapshotAtSevenDayBoundaryMaySupplyThen() {
        let day: TimeInterval = 86_400
        let product = makePriced(
            sizes: [(32, "oz"), (28, "oz")],
            prices: [(7 * day, 1.79), (8 * day, 1.89)]
        )
        let record = detector.analyze(product: product)

        XCTAssertEqual(record.priceThen ?? 0, 1.79, accuracy: 0.0001)
        XCTAssertEqual(record.costPerUnitThen ?? 0, 1.79 / 32, accuracy: 0.0001)
    }

    func test_invalidLivePriceDoesNotOverrideStoredCurrentPrice() {
        let product = makePriced(
            sizes: [(32, "oz"), (28, "oz")],
            prices: [(0, 1.79), (86_400, 1.89)]
        )

        XCTAssertEqual(detector.analyze(product: product, livePrice: 0).priceNow ?? 0, 1.89, accuracy: 0.0001)
        XCTAssertEqual(detector.analyze(product: product, livePrice: -2).priceNow ?? 0, 1.89, accuracy: 0.0001)
    }

    func test_priceHistory_isSortedByDate() {
        let product = makePriced(sizes: [(32, "oz"), (28, "oz")], prices: [(86_400, 1.89), (0, 1.79)])
        let record = detector.analyze(product: product)
        XCTAssertEqual(record.priceNow ?? 0, 1.89, accuracy: 0.0001)
        XCTAssertEqual(record.priceThen ?? 0, 1.79, accuracy: 0.0001)
    }

    // MARK: - priceIsFromStoreSnapshot (Phase 3 review I6 regression fix)

    func test_priceFromCurrentPriceFallback_isNotFromStoreSnapshot() {
        // No priceHistory at all — priceNow falls back to product.currentPrice,
        // exactly what TrendingEntry.toProduct() produces for curated Browse
        // cards. That price is not Kroger-derived and must not be attributed.
        let product = makeProduct(history: [
            .init(quantity: 32, unit: "oz"),
            .init(quantity: 28, unit: "oz")
        ], price: 1.89)
        let record = detector.analyze(product: product)
        XCTAssertNotNil(record.costPerUnitNow)
        XCTAssertFalse(record.priceIsFromStoreSnapshot)
    }

    func test_priceFromPriceHistory_isFromStoreSnapshot() {
        let product = makePriced(sizes: [(32, "oz"), (28, "oz")], prices: [(0, 1.79), (86_400, 1.89)])
        let record = detector.analyze(product: product)
        XCTAssertNotNil(record.costPerUnitNow)
        XCTAssertTrue(record.priceIsFromStoreSnapshot)
    }

    // MARK: - Shared cost-per-ounce (Phase 3 review M2/T17 — was duplicated in
    // LivePricePanel and AlternativesEngine; both now delegate here.)

    func test_costPerOunce_massConvertsGramsToOzEquivalent() {
        let cost = ShrinkDetector.costPerOunce(price: 3.53, quantity: 100, unitKind: "mass")
        XCTAssertEqual(cost ?? 0, 3.53 / (100 * 0.035274), accuracy: 0.0001)
    }

    func test_costPerOunce_volumeConvertsMillilitresToOzEquivalent() {
        let cost = ShrinkDetector.costPerOunce(price: 1.00, quantity: 828.058, unitKind: "volume")
        XCTAssertEqual(cost ?? 0, 1.00 / (828.058 * 0.033814), accuracy: 0.0001)
    }

    func test_costPerOunce_countPassesThroughUnchanged() {
        let cost = ShrinkDetector.costPerOunce(price: 6.00, quantity: 12, unitKind: "count")
        XCTAssertEqual(cost ?? 0, 0.5, accuracy: 0.0001)
    }

    func test_costPerOunce_nilWhenPriceMissing() {
        XCTAssertNil(ShrinkDetector.costPerOunce(price: nil, quantity: 100, unitKind: "mass"))
    }

    func test_costPerOunce_nilWhenQuantityZeroOrMissing() {
        XCTAssertNil(ShrinkDetector.costPerOunce(price: 1.0, quantity: 0, unitKind: "mass"))
        XCTAssertNil(ShrinkDetector.costPerOunce(price: 1.0, quantity: nil, unitKind: "mass"))
    }

    func test_costPerOunce_nilWhenUnitKindMissing() {
        XCTAssertNil(ShrinkDetector.costPerOunce(price: 1.0, quantity: 100, unitKind: nil))
    }

    // MARK: - C2 plausibility clamp (final fix wave)
    //
    // A same-kind pair from two *different* sources whose implied ratio is
    // outside 0.25x–4x is more likely a unit-parsing mismatch between
    // sources (e.g. a multipack total from one source vs. a per-unit size
    // from another) than a real shrink/growth.

    fileprivate func crossSourceProduct(previous: (Double, String), current: (Double, String)) -> ShrunkProduct {
        let now = Date()
        return ShrunkProduct(
            id: "test", name: "Test", brand: "", category: "", imageURL: nil,
            sizeHistory: [
                SizeRecord(date: now, quantity: previous.0, unit: "g", source: previous.1),
                SizeRecord(date: now.addingTimeInterval(86400), quantity: current.0, unit: "g", source: current.1)
            ],
            currentPrice: nil, currency: "USD"
        )
    }

    func test_crossSourceRatioBelowQuarter_clampsToInsufficientData() {
        // 4258.584 (fdc, whole 12-pack) -> 354.882 (kroger, one can):
        // ratio ~0.083, far under the 0.25x floor.
        let product = crossSourceProduct(previous: (4258.584, "fdc"), current: (354.882, "kroger"))
        let record = detector.analyze(product: product)
        XCTAssertEqual(record.verdict, .insufficientData)
    }

    func test_crossSourceRatioAboveFour_clampsToInsufficientData() {
        let product = crossSourceProduct(previous: (354.882, "kroger"), current: (4258.584, "fdc"))
        let record = detector.analyze(product: product)
        XCTAssertEqual(record.verdict, .insufficientData)
    }

    func test_crossSourceRatioExactlyFour_isInclusiveAndStillVerdicts() {
        // The bound is inclusive (">4x" / "<0.25x" is implausible, "=4x" is not).
        let product = crossSourceProduct(previous: (100, "fdc"), current: (400, "kroger"))
        let record = detector.analyze(product: product)
        XCTAssertEqual(record.verdict, .grew)
    }

    func test_crossSourceRatioExactlyQuarter_isInclusiveAndStillVerdicts() {
        let product = crossSourceProduct(previous: (400, "fdc"), current: (100, "kroger"))
        let record = detector.analyze(product: product)
        XCTAssertEqual(record.verdict, .significantShrink)
    }

    func test_sameSourceImplausibleRatio_isNotClamped() {
        // Same source, huge ratio — not a cross-source mismatch, so the
        // plausibility clamp must not swallow a real (if extreme) verdict.
        let product = crossSourceProduct(previous: (1000, "fdc"), current: (100, "fdc"))
        let record = detector.analyze(product: product)
        XCTAssertEqual(record.verdict, .significantShrink)
    }

    // MARK: - The single-snapshot record (spec §2, §4)
    //
    // 98.5 % of the catalogue has exactly one observation, and a fresh on-miss
    // lookup has none. `.insufficientData` is the right *verdict* for both, but
    // the record still has to carry everything the Result screen needs to say
    // something concrete: the size we do know, and what it costs per ounce.

    func test_singleObservation_setsCurrentSizeAndLeavesPreviousSizeNil() {
        let product = makeProduct(history: [.init(quantity: 28, unit: "oz")])
        let record = detector.analyze(product: product)

        XCTAssertEqual(record.verdict, .insufficientData)
        XCTAssertEqual(record.currentSize?.quantity, 28, "the one snapshot we have is the current size")
        XCTAssertNil(record.previousSize,
                     "there is no 'then' — reporting the same record as both ends rendered a Then→Now row comparing a size with itself")
    }

    func test_singleObservation_stillPricesCostPerOunce() {
        // Without this the screen's whole cost-per-oz section renders empty on
        // the commonest product in the catalogue.
        let product = makeProduct(history: [.init(quantity: 28, unit: "oz")], price: 1.89)
        let record = detector.analyze(product: product)

        XCTAssertEqual(record.costPerUnitNow ?? 0, 1.89 / 28, accuracy: 0.0001)
        XCTAssertNil(record.costPerUnitThen, "one snapshot has nothing to compare against")
    }

    func test_singleObservation_costPerOunceIsNilWithoutAPrice() {
        let product = makeProduct(history: [.init(quantity: 28, unit: "oz")], price: nil)
        XCTAssertNil(detector.analyze(product: product).costPerUnitNow)
    }

    func test_singleObservation_normalizesTheUnitBeforePricing() {
        // 946.353 ml is 32 fl-oz-equivalent; $1.89 over it is $1.89/32, not
        // $1.89/946.353.
        let product = makeProduct(history: [.init(quantity: 946.353, unit: "ml")], price: 1.89)
        let record = detector.analyze(product: product)
        XCTAssertEqual(record.costPerUnitNow ?? 0, 1.89 / (946.353 * 0.033814), accuracy: 0.0001)
    }

    func test_mixedKindsWithOnlyOneOfTheLatestKind_hasNoPreviousSize() {
        // 1000 g then 28 fl oz: one record of the latest kind, so there is a
        // current size but nothing legal to compare it with.
        let product = makeProduct(history: [
            .init(quantity: 1000, unit: "g"),
            .init(quantity: 28,   unit: "fl oz")
        ])
        let record = detector.analyze(product: product)

        XCTAssertEqual(record.verdict, .insufficientData)
        XCTAssertEqual(record.currentSize?.quantity, 28)
        XCTAssertNil(record.previousSize, "a mass record is never the 'then' for a volume one")
    }

    // MARK: - Adopting the live store size (spec rule 5)
    //
    // A product found through the on-miss lookup comes back with
    // `observations: []`, but the live Kroger row for the same GTIN often
    // parses a size. `analyze(product:liveSize:)` treats that size as the
    // current one so the screen has a fact to show and the Watch button has a
    // baseline. It is deliberately only consulted when the product has no
    // observation of its own — a stored observation always wins.

    func test_noObservations_hasNoCurrentSize() {
        let record = detector.analyze(product: makeProduct(history: []))
        XCTAssertEqual(record.verdict, .insufficientData)
        XCTAssertNil(record.currentSize)
    }

    func test_noObservations_withALiveSize_adoptsItAsTheCurrentSize() {
        let live = SizeRecord(date: Date(), quantity: 828.058, unit: "ml", source: "kroger")
        let record = detector.analyze(product: makeProduct(history: []), liveSize: live)

        XCTAssertEqual(record.verdict, .insufficientData)
        XCTAssertEqual(record.currentSize?.quantity, 828.058)
        XCTAssertEqual(record.currentSize?.unit, "ml")
        XCTAssertEqual(record.currentSize?.source, "kroger", "attribution survives adoption")
        XCTAssertNil(record.previousSize)
    }

    func test_adoptedLiveSize_pricesCostPerOunce() {
        let live = SizeRecord(date: Date(), quantity: 828.058, unit: "ml", source: "kroger")
        let record = detector.analyze(product: makeProduct(history: [], price: 1.89), liveSize: live)
        XCTAssertEqual(record.costPerUnitNow ?? 0, 1.89 / (828.058 * 0.033814), accuracy: 0.0001)
    }

    func test_liveSizeIsIgnoredWhenTheProductAlreadyHasAnObservation() {
        // Our own observation is the record of truth; a live row is only a
        // stand-in for having none at all.
        let live = SizeRecord(date: Date(), quantity: 828.058, unit: "ml", source: "kroger")
        let product = makeProduct(history: [.init(quantity: 946.353, unit: "ml")])
        let record = detector.analyze(product: product, liveSize: live)

        XCTAssertEqual(record.currentSize?.quantity, 946.353)
        XCTAssertEqual(record.currentSize?.source, "test")
    }

    func test_liveSizeOfZeroIsNotAdopted() {
        let live = SizeRecord(date: Date(), quantity: 0, unit: "ml", source: "kroger")
        let record = detector.analyze(product: makeProduct(history: []), liveSize: live)
        XCTAssertNil(record.currentSize, "a zero quantity is not a size")
    }

    // MARK: - Using the live store price
    //
    // `ProductDTO.toProduct` sets `currentPrice: prices.last?.price`, so a
    // product with no `price_snapshots` has no price at all — which is every
    // fresh on-miss lookup. Without adopting the live price too, the
    // single-snapshot row keeps its size promise but breaks its per-ounce one:
    // the cost/oz card hides, the cheapest-per-oz callout never renders, and
    // `AlternativesEngine` gets `scannedCostPerOz == nil` so no candidate can
    // say "N % cheaper".

    func test_noPriceOfItsOwn_adoptsTheLivePrice() {
        let record = detector.analyze(
            product: makeProduct(history: [.init(quantity: 28, unit: "oz")], price: nil),
            livePrice: 1.89
        )
        XCTAssertEqual(record.priceNow ?? 0, 1.89, accuracy: 0.0001)
        XCTAssertEqual(record.costPerUnitNow ?? 0, 1.89 / 28, accuracy: 0.0001)
    }

    func test_anAdoptedLivePriceCarriesStoreAttribution() {
        // A live Kroger price *is* Kroger data, so the cost/oz card must show
        // `LivePrice.attribution` over it — unlike a curated trending.json
        // price, which is what this flag exists to keep unattributed.
        let record = detector.analyze(
            product: makeProduct(history: [.init(quantity: 28, unit: "oz")], price: nil),
            livePrice: 1.89
        )
        XCTAssertTrue(record.priceIsFromStoreSnapshot)
    }

    func test_livePriceWinsOverEditorialCurrentPrice() {
        let record = detector.analyze(
            product: makeProduct(history: [.init(quantity: 28, unit: "oz")], price: 2.49),
            livePrice: 1.89
        )
        XCTAssertEqual(record.priceNow ?? 0, 1.89, accuracy: 0.0001)
        XCTAssertEqual(record.costPerUnitNow ?? 0, 1.89 / 28, accuracy: 0.0001)
        XCTAssertTrue(record.priceIsFromStoreSnapshot)
    }

    func test_livePriceWinsOverCachedPriceSnapshot() {
        let product = makePriced(sizes: [(32, "oz"), (28, "oz")], prices: [(0, 1.79), (86_400, 1.89)])
        let record = detector.analyze(product: product, livePrice: 9.99)
        XCTAssertEqual(record.priceNow ?? 0, 9.99, accuracy: 0.0001)
        XCTAssertEqual(record.costPerUnitNow ?? 0, 9.99 / 28, accuracy: 0.0001)
        XCTAssertEqual(record.priceThen ?? 0, 1.79, accuracy: 0.0001)
    }

    /// The exact case the spec was written for: Gatorade `0052000338317`
    /// comes back with `observations: []` and no price snapshots, and the live
    /// Kroger row supplies both halves.
    func test_freshLookup_adoptsBothTheLiveSizeAndTheLivePrice() {
        let live = SizeRecord(date: Date(), quantity: 828.058, unit: "ml", source: "kroger")
        let record = detector.analyze(
            product: makeProduct(history: [], price: nil), liveSize: live, livePrice: 1.89
        )

        XCTAssertEqual(record.currentSize?.quantity, 828.058)
        XCTAssertEqual(record.priceNow ?? 0, 1.89, accuracy: 0.0001)
        XCTAssertEqual(record.costPerUnitNow ?? 0, 1.89 / (828.058 * 0.033814), accuracy: 0.0001)
        XCTAssertTrue(record.priceIsFromStoreSnapshot)
        XCTAssertEqual(record.verdict, .insufficientData)
    }

    func test_aLivePriceWithNoSizeAtAllGivesNoCostPerOunce() {
        let record = detector.analyze(product: makeProduct(history: [], price: nil), livePrice: 1.89)
        XCTAssertNil(record.currentSize)
        XCTAssertEqual(record.priceNow ?? 0, 1.89, accuracy: 0.0001)
        XCTAssertNil(record.costPerUnitNow, "a price over an unknown size is not a per-ounce number")
    }

    func test_theLivePriceIsAdoptedOnTheShrinkPathToo() {
        // Two observations, no stored price — the verdict path still needs a
        // per-ounce number for the alternatives ranking to compare against.
        let product = makeProduct(history: [
            .init(quantity: 32, unit: "oz"),
            .init(quantity: 28, unit: "oz")
        ], price: nil)
        let record = detector.analyze(product: product, livePrice: 1.89)

        XCTAssertEqual(record.verdict, .significantShrink)
        XCTAssertEqual(record.costPerUnitNow ?? 0, 1.89 / 28, accuracy: 0.0001)
        XCTAssertNil(record.costPerUnitThen, "one live price is not a history")
    }

    // MARK: - Size runs (spec §5.1)
    //
    // The verdict compares the last two *runs*, not the last two observations.
    // Consecutive observations that agree within 1% are one run — so a second
    // source confirming today's size can no longer erase a documented shrink
    // by pairing "450 g (curated)" against "450 g (USDA)" and reporting
    // +0.0 % / Unchanged. Eight of the 25 verified curated cases scored "no
    // shrink" for exactly that reason (.curated-verify-report.md §5).

    /// (quantity, unit, source), one day apart, oldest first.
    fileprivate func makeRunHistory(_ points: [(Double, String, String)]) -> ShrunkProduct {
        let base = Date(timeIntervalSince1970: 1_600_000_000)
        let records = points.enumerated().map { idx, point in
            SizeRecord(
                date: base.addingTimeInterval(TimeInterval(idx) * 86_400),
                quantity: point.0,
                unit: point.1,
                source: point.2
            )
        }
        return ShrunkProduct(
            id: "test", name: "Test", brand: "Brand", category: "Dairy", imageURL: nil,
            sizeHistory: records, currentPrice: nil, currency: "USD"
        )
    }

    func test_aConfirmingObservationDoesNotEraseTheShrink() {
        // Fage-shaped: the curated pair documents 500 g -> 450 g, then USDA
        // FDC independently reports the same 450 g. The last two observations
        // are 450/450, but the last two *runs* are 500 -> 450.
        let product = makeRunHistory([
            (500, "g", "curated"),
            (450, "g", "curated"),
            (450, "g", "fdc")
        ])
        let record = detector.analyze(product: product)

        XCTAssertEqual(record.verdict, .moderateShrink)
        XCTAssertEqual(record.shrinkPercent, -10, accuracy: 0.0001)
        XCTAssertEqual(record.previousSize?.quantity, 500)
        XCTAssertEqual(record.currentSize?.quantity, 450)
    }

    func test_previousAndCurrentKeepTheOpeningEvidenceDateAndSource() {
        // Quantity, date, and source must come from the same observation;
        // later confirmations remain supporting sources, not replacement dates.
        let product = makeRunHistory([
            (500, "g", "curated"),   // day 0
            (500, "g", "fdc"),       // day 1 confirmation
            (450, "g", "curated"),   // day 2 opens current run
            (450, "g", "fdc")        // day 3 confirmation
        ])
        let record = detector.analyze(product: product)
        let base = Date(timeIntervalSince1970: 1_600_000_000)

        XCTAssertEqual(record.previousSize?.date, base)
        XCTAssertEqual(record.previousSize?.source, "curated")
        XCTAssertEqual(record.currentSize?.date, base.addingTimeInterval(2 * 86_400))
        XCTAssertEqual(record.currentSize?.source, "curated")
    }

    func test_threeRunsCompareTheLastTwo() {
        // 500 / 450 / 450 / 400 -> runs [500] [450 450] [400]; the verdict is
        // 450 -> 400, not 500 -> 400 and not 450 -> 450.
        let product = makeRunHistory([
            (500, "g", "curated"),
            (450, "g", "curated"),
            (450, "g", "fdc"),
            (400, "g", "kroger")
        ])
        let record = detector.analyze(product: product)

        XCTAssertEqual(record.previousSize?.quantity, 450)
        XCTAssertEqual(record.currentSize?.quantity, 400)
        XCTAssertEqual(record.shrinkPercent, -100.0 / 9.0, accuracy: 0.0001)  // -11.1%
        XCTAssertEqual(record.verdict, .significantShrink)
    }

    func test_measurementNoiseWithinToleranceStaysOneRun() {
        // 450 -> 452 (+0.44%) -> 450: three observations, one run, no verdict.
        let product = makeRunHistory([
            (450, "g", "curated"),
            (452, "g", "fdc"),
            (450, "g", "kroger")
        ])
        let record = detector.analyze(product: product)

        XCTAssertEqual(record.verdict, .insufficientData)
        XCTAssertNil(record.previousSize, "one run has no 'then'")
        XCTAssertEqual(record.currentSize?.quantity, 450)
        XCTAssertEqual(record.currentSize?.date, Date(timeIntervalSince1970: 1_600_000_000),
                       "ResultView dates this state 'first seen …' — a later confirmation of the same size is not a first sighting")
    }

    func test_runsAreBuiltOnlyFromTheLatestKind() {
        // A volume observation can never join or precede a mass run, however
        // close the numbers look after normalization.
        let product = makeRunHistory([
            (450, "ml", "fdc"),      // volume — ignored entirely
            (500, "g", "curated"),
            (450, "g", "curated"),
            (450, "g", "fdc")
        ])
        let record = detector.analyze(product: product)

        XCTAssertEqual(record.verdict, .moderateShrink)
        XCTAssertEqual(record.previousSize?.quantity, 500)
        XCTAssertEqual(record.previousSize?.unit, "g")
        XCTAssertEqual(record.currentSize?.unit, "g")
    }

    func test_crossKindOnlyAfterTheLatestKindStillGivesNoVerdict() {
        // The mass history is real, but the newest observation is volume, so
        // there is exactly one same-kind run and nothing to compare.
        let product = makeRunHistory([
            (500, "g", "curated"),
            (450, "g", "curated"),
            (450, "ml", "fdc")
        ])
        let record = detector.analyze(product: product)

        XCTAssertEqual(record.verdict, .insufficientData)
        XCTAssertNil(record.previousSize)
        XCTAssertEqual(record.currentSize?.unit, "ml")
    }

    func test_theClampStillAppliesToTheRunPair() {
        // The OREO case, with a confirming row appended: the run pair is still
        // fdc 530 g -> kroger 31.5 g, a ratio of 0.06, so it is refused.
        let product = makeRunHistory([
            (530, "g", "fdc"),
            (31.468, "g", "kroger"),
            (31.468, "g", "kroger")
        ])
        XCTAssertEqual(detector.analyze(product: product).verdict, .insufficientData)
    }

    func test_aSameSourceRunPairIsNeverClamped() {
        let product = makeRunHistory([
            (1000, "g", "fdc"),
            (100, "g", "fdc"),
            (100, "g", "fdc")
        ])
        XCTAssertEqual(detector.analyze(product: product).verdict, .significantShrink)
    }
}
