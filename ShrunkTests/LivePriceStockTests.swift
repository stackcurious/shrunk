import XCTest
@testable import Shrunk

/// `StorePriced.inStock` used to answer "true" for a missing or unrecognised
/// `stockLevel`, so a row we know nothing about rendered in the green in-stock
/// capsule next to the label "Stock unknown". Green is a promise the product is
/// on the shelf; we can only make it when the store said so.
final class LivePriceStockTests: XCTestCase {

    private func price(stock: String?) -> LivePrice {
        LivePrice(
            gtin: "0000000000017", locationId: "01400355", brand: "Brand",
            description: "Thing", size: "12 oz", quantity: 340.194, unitKind: "mass",
            regular: 3.49, promo: nil, perUnitEstimate: nil, stockLevel: stock
        )
    }

    func test_knownStockLevelsMapToTheirState() {
        XCTAssertEqual(price(stock: "HIGH").stockState, .inStock)
        XCTAssertEqual(price(stock: "LOW").stockState, .low)
        XCTAssertEqual(price(stock: "TEMPORARILY_OUT_OF_STOCK").stockState, .outOfStock)
    }

    func test_missingOrUnrecognisedStockLevelIsUnknownNotInStock() {
        for level in [nil, "", "SOMETHING_NEW"] as [String?] {
            let live = price(stock: level)
            XCTAssertEqual(live.stockState, .unknown, "level \(String(describing: level))")
            XCTAssertFalse(live.inStock, "unknown stock must not read as in stock (\(String(describing: level)))")
            XCTAssertFalse(live.isOutOfStock, "unknown stock must not read as out of stock either")
            XCTAssertEqual(live.stockLabel, "Stock unknown")
        }
    }

    func test_lowStockStillCountsAsOnTheShelf() {
        XCTAssertTrue(price(stock: "LOW").inStock)
        XCTAssertFalse(price(stock: "LOW").isOutOfStock)
    }

    func test_outOfStockIsTheOnlyLevelThatFailsTheAlternativesFilter() {
        XCTAssertTrue(price(stock: "TEMPORARILY_OUT_OF_STOCK").isOutOfStock)
        XCTAssertFalse(price(stock: "HIGH").isOutOfStock)
    }
}
