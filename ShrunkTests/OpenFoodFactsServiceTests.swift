import XCTest
@testable import Shrunk

final class OpenFoodFactsServiceTests: XCTestCase {

    // MARK: - parseQuantity — happy paths

    func test_parseQuantity_flOzWithSpace() {
        let parsed = OpenFoodFactsService.parseQuantity("28 fl oz")
        XCTAssertEqual(parsed?.quantity, 28)
        XCTAssertEqual(parsed?.unit, "fl oz")
    }

    func test_parseQuantity_flOzNoSpace() {
        let parsed = OpenFoodFactsService.parseQuantity("28floz")
        XCTAssertEqual(parsed?.quantity, 28)
        XCTAssertEqual(parsed?.unit, "fl oz")
    }

    func test_parseQuantity_grams_compact() {
        let parsed = OpenFoodFactsService.parseQuantity("500g")
        XCTAssertEqual(parsed?.quantity, 500)
        XCTAssertEqual(parsed?.unit, "g")
    }

    func test_parseQuantity_litersCapitalL() {
        let parsed = OpenFoodFactsService.parseQuantity("1.5L")
        XCTAssertEqual(parsed?.quantity, 1.5)
        XCTAssertEqual(parsed?.unit, "l")
    }

    func test_parseQuantity_milliliters() {
        let parsed = OpenFoodFactsService.parseQuantity("330 ml")
        XCTAssertEqual(parsed?.quantity, 330)
        XCTAssertEqual(parsed?.unit, "ml")
    }

    func test_parseQuantity_count_word() {
        let parsed = OpenFoodFactsService.parseQuantity("12 count")
        XCTAssertEqual(parsed?.quantity, 12)
        XCTAssertEqual(parsed?.unit, "count")
    }

    func test_parseQuantity_count_ctAbbrev() {
        let parsed = OpenFoodFactsService.parseQuantity("24ct")
        XCTAssertEqual(parsed?.quantity, 24)
        XCTAssertEqual(parsed?.unit, "count")
    }

    func test_parseQuantity_pkAlias() {
        let parsed = OpenFoodFactsService.parseQuantity("6 pk")
        XCTAssertEqual(parsed?.quantity, 6)
        XCTAssertEqual(parsed?.unit, "count")
    }

    // MARK: - Locale and formatting variants

    func test_parseQuantity_commaDecimal_isAccepted() {
        let parsed = OpenFoodFactsService.parseQuantity("1,5 L")
        XCTAssertEqual(parsed?.quantity, 1.5)
    }

    func test_parseQuantity_uppercaseInput() {
        let parsed = OpenFoodFactsService.parseQuantity("28 FL OZ")
        XCTAssertEqual(parsed?.quantity, 28)
        XCTAssertEqual(parsed?.unit, "fl oz")
    }

    func test_parseQuantity_extraWhitespace() {
        let parsed = OpenFoodFactsService.parseQuantity("   500   g   ")
        XCTAssertEqual(parsed?.quantity, 500)
        XCTAssertEqual(parsed?.unit, "g")
    }

    // MARK: - Failure cases

    func test_parseQuantity_emptyString_returnsNil() {
        XCTAssertNil(OpenFoodFactsService.parseQuantity(""))
    }

    func test_parseQuantity_nonsense_returnsNil() {
        XCTAssertNil(OpenFoodFactsService.parseQuantity("a bag of crisps"))
    }

    func test_parseQuantity_unitless_returnsNil() {
        XCTAssertNil(OpenFoodFactsService.parseQuantity("28"))
    }

    // MARK: - OFFProduct → ShrunkProduct mapping

    func test_mapToProduct_basic() {
        let off = OFFProduct(
            productName: "Pepsi Cola",
            genericName: nil,
            brands: "Pepsi, PepsiCo",
            quantity: "16.9 fl oz",
            quantityImported: "20 fl oz",
            categoriesTags: ["en:beverages", "en:carbonated-drinks"],
            imageUrl: "https://example.com/pepsi.jpg",
            lastModifiedT: Int(Date().timeIntervalSince1970),
            createdT: Int(Date().timeIntervalSince1970 - 86400 * 365)
        )

        let mapped = OpenFoodFactsService.mapToProduct(off, barcode: "0123456789012")

        XCTAssertEqual(mapped.id, "0123456789012")
        XCTAssertEqual(mapped.name, "Pepsi Cola")
        XCTAssertEqual(mapped.brand, "Pepsi")
        XCTAssertEqual(mapped.category, "Carbonated Drinks")
        XCTAssertEqual(mapped.imageURL?.absoluteString, "https://example.com/pepsi.jpg")
        XCTAssertEqual(mapped.sizeHistory.count, 2)
        XCTAssertEqual(mapped.sizeHistory.first?.quantity, 20)
        XCTAssertEqual(mapped.sizeHistory.last?.quantity, 16.9)
    }

    func test_mapToProduct_missingName_fallsBackGracefully() {
        let off = OFFProduct(
            productName: nil, genericName: nil, brands: nil,
            quantity: "10 oz", quantityImported: nil,
            categoriesTags: nil, imageUrl: nil,
            lastModifiedT: nil, createdT: nil
        )
        let mapped = OpenFoodFactsService.mapToProduct(off, barcode: "1")
        XCTAssertEqual(mapped.name, "Unknown product")
        XCTAssertEqual(mapped.category, "Uncategorized")
        XCTAssertEqual(mapped.brand, "")
    }

    func test_buildHistory_sameQuantity_doesNotInsertImported() {
        let off = OFFProduct(
            productName: "Static product",
            genericName: nil, brands: nil,
            quantity: "16 oz", quantityImported: "16 oz",
            categoriesTags: nil, imageUrl: nil,
            lastModifiedT: 0, createdT: 0
        )
        let history = OpenFoodFactsService.buildHistory(from: off)
        XCTAssertEqual(history.count, 1, "should not duplicate identical quantity")
    }

    func test_buildHistory_changedQuantity_insertsImportedFirst() {
        let off = OFFProduct(
            productName: "Shrunk product",
            genericName: nil, brands: nil,
            quantity: "12 oz", quantityImported: "16 oz",
            categoriesTags: nil, imageUrl: nil,
            lastModifiedT: Int(Date().timeIntervalSince1970),
            createdT: Int(Date().timeIntervalSince1970 - 86400)
        )
        let history = OpenFoodFactsService.buildHistory(from: off)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.first?.quantity, 16)
        XCTAssertEqual(history.last?.quantity, 12)
        XCTAssertLessThan(history.first!.date, history.last!.date)
    }
}
