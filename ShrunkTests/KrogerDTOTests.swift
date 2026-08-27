import XCTest
@testable import Shrunk

final class KrogerDTOTests: XCTestCase {
    private let decoder = JSONDecoder()

    func test_locationsResponse_decodesAndMaps() throws {
        let json = """
        {"locations":[{"locationId":"01400943","chain":"KROGER","name":"Hyde Park",
          "address":{"addressLine1":"3760 Paxton Ave","city":"Cincinnati","state":"OH","zipCode":"45209"},
          "geolocation":{"latitude":39.14,"longitude":-84.42}}],
         "attribution":"Prices from Kroger"}
        """
        let dto = try decoder.decode(LocationsResponseDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.attribution, "Prices from Kroger")

        let store = dto.locations[0].toModel()
        XCTAssertEqual(store.id, "01400943")
        XCTAssertEqual(store.displayName, "Kroger Hyde Park")
        XCTAssertEqual(store.addressLine, "3760 Paxton Ave · Cincinnati, OH")
        XCTAssertEqual(store.zipCode, "45209")
    }

    func test_liveProduct_decodesAndMaps() throws {
        let json = """
        {"gtin":"0028400642255","location_id":"01400943","product_id":"0002840064225",
         "brand":"Gatorade","description":"Gatorade Thirst Quencher","category":"Beverages",
         "image_url":"https://img/large.jpg","size":"28 fl oz","quantity":828.058,"unit_kind":"volume",
         "regular":1.89,"promo":1.5,"per_unit_estimate":0.05,"price_per_base_unit":0.00181,
         "stock_level":"HIGH","attribution":"Prices from Kroger"}
        """
        let live = try decoder.decode(LiveProductDTO.self, from: Data(json.utf8)).toModel()
        XCTAssertEqual(live.gtin, "0028400642255")
        XCTAssertEqual(live.locationId, "01400943")
        XCTAssertEqual(live.size, "28 fl oz")
        XCTAssertEqual(live.quantity ?? 0, 828.058, accuracy: 0.001)
        XCTAssertEqual(live.unitKind, "volume")
        XCTAssertEqual(live.effectivePrice, 1.5)          // promo wins
        XCTAssertTrue(live.isOnPromo)
        XCTAssertTrue(live.inStock)
        XCTAssertEqual(live.stockLabel, "In stock")
        XCTAssertEqual(LivePrice.attribution, "Prices from Kroger")
    }

    func test_liveProduct_outOfStockAndNoPromo() throws {
        let json = """
        {"gtin":"0028400642255","location_id":"01400943","product_id":"0002840064225",
         "brand":"","description":"X","category":"","image_url":null,"size":"each",
         "quantity":null,"unit_kind":null,"regular":3.49,"promo":0,"per_unit_estimate":null,
         "price_per_base_unit":null,"stock_level":"TEMPORARILY_OUT_OF_STOCK","attribution":"Prices from Kroger"}
        """
        let live = try decoder.decode(LiveProductDTO.self, from: Data(json.utf8)).toModel()
        XCTAssertEqual(live.effectivePrice, 3.49)
        XCTAssertFalse(live.isOnPromo)
        XCTAssertFalse(live.inStock)
        XCTAssertEqual(live.stockLabel, "Out of stock")
        XCTAssertNil(live.quantity)
    }

    func test_searchResponse_decodesAndMaps() throws {
        let json = """
        {"results":[{"gtin":"0002840064226","product_id":"0002840064226","brand":"Store",
          "description":"Store Brand","category":"Beverages","image_url":null,"size":"32 fl oz",
          "quantity":946.353,"unit_kind":"volume","regular":1.0,"promo":0,
          "per_unit_estimate":0.03,"price_per_base_unit":0.00106,"stock_level":"LOW"}],
         "attribution":"Prices from Kroger"}
        """
        let dto = try decoder.decode(SearchResponseDTO.self, from: Data(json.utf8))
        let result = dto.results[0].toModel()
        XCTAssertEqual(result.gtin, "0002840064226")
        XCTAssertEqual(result.description, "Store Brand")
        XCTAssertEqual(result.effectivePrice, 1.0)
        XCTAssertEqual(result.stockLabel, "Low stock")
        XCTAssertTrue(result.inStock)
        XCTAssertEqual(result.quantity ?? 0, 946.353, accuracy: 0.001)
    }
}
