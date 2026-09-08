import XCTest
@testable import Shrunk

final class CategoryDetailLogicTests: XCTestCase {
    func test_summarySubtitleAveragesPercentagePointsWithoutMultiplyingAgain() {
        let records = [makeRecord(shrinkPercent: -12.5), makeRecord(shrinkPercent: -7.5)]

        XCTAssertEqual(
            CategoryDetailView.summarySubtitle(for: records),
            "2 tracked cases · avg 10.0% shrink"
        )
    }

    func test_summarySubtitleHandlesEmptyCategory() {
        XCTAssertEqual(
            CategoryDetailView.summarySubtitle(for: []),
            "No documented cases yet in this category."
        )
    }

    private func makeRecord(shrinkPercent: Double) -> ShrinkRecord {
        let product = ShrunkProduct(
            id: UUID().uuidString,
            name: "Test",
            brand: "Brand",
            category: "Snacks",
            imageURL: nil,
            sizeHistory: [],
            currentPrice: nil,
            currency: "USD"
        )
        return ShrinkRecord(
            product: product,
            previousSize: nil,
            currentSize: nil,
            shrinkPercent: shrinkPercent,
            priceThen: nil,
            priceNow: nil,
            costPerUnitThen: nil,
            costPerUnitNow: nil,
            priceIsFromStoreSnapshot: false,
            verdict: .insufficientData
        )
    }
}
