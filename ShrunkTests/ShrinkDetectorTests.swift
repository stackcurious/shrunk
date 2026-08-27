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

    func test_unchanged_withinOnePercent() {
        let product = makeProduct(history: [
            .init(quantity: 1000, unit: "ml"),
            .init(quantity: 999, unit: "ml")  // -0.1%
        ])
        let record = detector.analyze(product: product)
        XCTAssertEqual(record.verdict, .unchanged)
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
}

