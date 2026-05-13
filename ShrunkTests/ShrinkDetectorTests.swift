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
}

