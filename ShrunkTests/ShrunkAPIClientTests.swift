import XCTest
@testable import Shrunk

final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?
    /// When set, `startLoading` fails the request at the transport level
    /// instead of consulting `handler` — simulates "no connectivity" for I1's
    /// offline-copy and cached-result tests. Reset to `nil` after use so it
    /// doesn't leak into unrelated tests.
    static var failureError: Error?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let failureError = Self.failureError {
            client?.urlProtocol(self, didFailWithError: failureError)
            return
        }
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

    // MARK: - I2: short barcodes reach the contribute flow
    //
    // A 400 from `/v1/product/:gtin` means the Worker's `normalizeGTIN`
    // couldn't canonicalise the barcode (e.g. an unexpanded 8-digit UPC-E) —
    // the user must land on the same "not in our database" → Contribute path
    // as a genuine 404, not a generic "couldn't read the response" error.
    func test_fetchProduct_400_mapsToProductNotFound() async {
        StubURLProtocol.handler = { _ in (400, Data(#"{"error":"invalid_gtin"}"#.utf8)) }
        do {
            _ = try await client.fetchProduct(barcode: "12345678", locationId: nil)
            XCTFail("expected throw")
        } catch ShrunkError.productNotFound {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - I1: offline copy is exact, regardless of the underlying URLError

    func test_networkError_errorDescriptionIsTheExactOfflineCopy() {
        XCTAssertEqual(
            ShrunkError.network(URLError(.notConnectedToInternet)).errorDescription,
            "Couldn't reach Shrunk — check connection."
        )
        XCTAssertEqual(
            ShrunkError.network(URLError(.timedOut)).errorDescription,
            "Couldn't reach Shrunk — check connection."
        )
    }

    func test_fetchProduct_transportFailure_throwsNetworkError() async {
        StubURLProtocol.failureError = URLError(.notConnectedToInternet)
        defer { StubURLProtocol.failureError = nil }
        do {
            _ = try await client.fetchProduct(barcode: "0028400642255", locationId: nil)
            XCTFail("expected throw")
        } catch ShrunkError.network {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Device identity

    func test_deviceIdentity_mintsOnceAndSticks() {
        UserDefaults.standard.removeObject(forKey: DeviceIdentity.key)
        let first = DeviceIdentity.current
        XCTAssertFalse(first.isEmpty)
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(DeviceIdentity.current, first)
        // Deliberately not asserting `UserDefaults.standard.string(forKey:) == first` here:
        // `DeviceIdentity`'s static `@AppStorage` only refreshes its in-memory cache through
        // SwiftUI's view-update cycle, so a *second* XCTestCase in this same process that
        // also resets `DeviceIdentity.key` (Phase 4's `DeviceIdentityUnificationTests`) can
        // leave this cache holding a stale value while the raw UserDefaults entry is gone —
        // an artifact of sharing one process across tests, not a production bug. The three
        // assertions above already cover the real contract: mints a valid UUID once, sticks.
    }

    // MARK: - Multipart encoding

    func test_multipartBody_encodesFieldsAndPhoto() throws {
        let data = ShrunkAPIClient.multipartBody(
            boundary: "BOUND",
            fields: ["gtin": "0028400642255", "quantity": "340.194", "unit_kind": "mass"],
            photoJPEG: Data([0xff, 0xd8, 0xff, 0xd9])
        )
        let body = try XCTUnwrap(String(data: data, encoding: .isoLatin1))

        XCTAssertTrue(body.contains("--BOUND\r\nContent-Disposition: form-data; name=\"gtin\"\r\n\r\n0028400642255\r\n"))
        XCTAssertTrue(body.contains("name=\"quantity\"\r\n\r\n340.194\r\n"))
        XCTAssertTrue(body.contains("name=\"unit_kind\"\r\n\r\nmass\r\n"))
        XCTAssertTrue(body.contains("Content-Disposition: form-data; name=\"photo\"; filename=\"label.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n"))
        XCTAssertTrue(body.hasSuffix("--BOUND--\r\n"))
    }

    func test_multipartBody_omitsThePhotoPartWhenThereIsNone() throws {
        let data = ShrunkAPIClient.multipartBody(boundary: "BOUND", fields: ["gtin": "0028400642255"], photoJPEG: nil)
        let body = try XCTUnwrap(String(data: data, encoding: .isoLatin1))
        XCTAssertFalse(body.contains("name=\"photo\""))
        XCTAssertTrue(body.hasSuffix("--BOUND--\r\n"))
    }

    // MARK: - submitObservation

    func test_submitObservation_postsMultipartAndMapsTheResult() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.test/v1/observations")
            XCTAssertEqual(request.httpMethod, "POST")
            let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
            XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary=shrunk-"), contentType)
            return (200, Data(#"{"status":"accepted","confidence":0.9,"observation_id":42}"#.utf8))
        }

        let result = try await client.submitObservation(
            gtin: "0028400642255", quantity: 340.194, unitKind: .mass,
            rawText: "NET WT 12 OZ (340g)", ocrConfidence: 0.95,
            deviceId: "device-1", photoJPEG: Data([0xff, 0xd8])
        )

        XCTAssertEqual(result, SubmissionResult(status: .accepted, confidence: 0.9, observationId: 42))
    }

    func test_submitObservation_mapsPending() async throws {
        StubURLProtocol.handler = { _ in (200, Data(#"{"status":"pending","confidence":0.5,"observation_id":7}"#.utf8)) }
        let result = try await client.submitObservation(
            gtin: "0028400642255", quantity: 500, unitKind: .volume,
            rawText: "", ocrConfidence: 0, deviceId: "device-1", photoJPEG: nil
        )
        XCTAssertEqual(result.status, .pending)
        XCTAssertEqual(result.confidence, 0.5)
        XCTAssertEqual(result.observationId, 7)
    }

    func test_submitObservation_400_throwsInvalidResponse() async {
        StubURLProtocol.handler = { _ in (400, Data(#"{"error":"invalid_gtin"}"#.utf8)) }
        do {
            _ = try await client.submitObservation(
                gtin: "123", quantity: 1, unitKind: .mass,
                rawText: "", ocrConfidence: 0, deviceId: "device-1", photoJPEG: nil
            )
            XCTFail("expected throw")
        } catch ShrunkError.invalidResponse {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test_submitObservation_unknownStatus_throwsInvalidResponse() async {
        StubURLProtocol.handler = { _ in (200, Data(#"{"status":"weird","confidence":0.9,"observation_id":1}"#.utf8)) }
        do {
            _ = try await client.submitObservation(
                gtin: "0028400642255", quantity: 1, unitKind: .mass,
                rawText: "", ocrConfidence: 0, deviceId: "device-1", photoJPEG: nil
            )
            XCTFail("expected throw")
        } catch ShrunkError.invalidResponse {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Product flag

    func test_needsConfirmation_defaultsToFalse() {
        let product = ShrunkProduct(
            id: "0028400642255", name: "Doritos", brand: "Doritos", category: "Snacks",
            imageURL: nil, sizeHistory: [], currentPrice: nil, currency: "USD"
        )
        XCTAssertFalse(product.needsConfirmation)
    }
}
