import XCTest
@testable import Shrunk

final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.handler!(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ShrunkAPIClientTests: XCTestCase {
    private var client: ShrunkAPIClient!

    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        client = ShrunkAPIClient(baseURL: URL(string: "https://api.test")!, session: URLSession(configuration: config))
    }

    func test_fetchProduct_mapsObservationsAndPrice() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.test/v1/product/0028400642255?locationId=01400943")
            let json = """
            {"gtin":"0028400642255","name":"Gatorade","brand":"Gatorade","category":"Beverages","image_url":"https://img/x.jpg","unit_kind":"volume",
             "observations":[
               {"quantity":946.353,"unit_kind":"volume","raw_text":"32 fl oz","observed_at":1517443200,"source":"fdc","source_ref":"1","confidence":0.9},
               {"quantity":828.058,"unit_kind":"volume","raw_text":"28 fl oz","observed_at":1625097600,"source":"kroger","source_ref":"01400943","confidence":0.8}],
             "price_snapshots":[{"location_id":"01400943","regular":1.89,"promo":0,"per_unit_estimate":0.07,"size_raw":"28 fl oz","stock_level":"HIGH","observed_at":1700000000}]}
            """
            return (200, Data(json.utf8))
        }

        let product = try await client.fetchProduct(barcode: "0028400642255", locationId: "01400943")

        XCTAssertEqual(product.id, "0028400642255")
        XCTAssertEqual(product.name, "Gatorade")
        XCTAssertEqual(product.category, "Beverages")
        XCTAssertEqual(product.imageURL?.absoluteString, "https://img/x.jpg")
        XCTAssertEqual(product.sizeHistory.count, 2)
        XCTAssertEqual(product.sizeHistory[0].quantity, 946.353, accuracy: 0.001)
        XCTAssertEqual(product.sizeHistory[0].unit, "ml")
        XCTAssertEqual(product.sizeHistory[0].source, "fdc")
        XCTAssertEqual(product.sizeHistory[0].date.timeIntervalSince1970, 1517443200)
        XCTAssertEqual(product.sizeHistory[1].source, "kroger")
        XCTAssertEqual(product.currentPrice, 1.89)
    }

    func test_fetchProduct_massUnitAndNoPrice() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.test/v1/product/0028400642255")
            let json = """
            {"gtin":"0028400642255","name":"Doritos","brand":"Doritos","category":"","image_url":null,"unit_kind":"mass",
             "observations":[{"quantity":340.194,"unit_kind":"mass","raw_text":"12 oz","observed_at":1517443200,"source":"fdc","source_ref":"1","confidence":0.9}],
             "price_snapshots":[]}
            """
            return (200, Data(json.utf8))
        }
        let product = try await client.fetchProduct(barcode: "0028400642255", locationId: nil)
        XCTAssertEqual(product.sizeHistory[0].unit, "g")
        XCTAssertNil(product.currentPrice)
        XCTAssertNil(product.imageURL)
    }

    func test_fetchProduct_404_throwsNotFound() async {
        StubURLProtocol.handler = { _ in (404, Data(#"{"error":"not_found"}"#.utf8)) }
        do {
            _ = try await client.fetchProduct(barcode: "0099999999999", locationId: nil)
            XCTFail("expected throw")
        } catch ShrunkError.productNotFound {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test_fetchProduct_500_throwsInvalidResponse() async {
        StubURLProtocol.handler = { _ in (500, Data()) }
        do {
            _ = try await client.fetchProduct(barcode: "0028400642255", locationId: nil)
            XCTFail("expected throw")
        } catch ShrunkError.invalidResponse {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
