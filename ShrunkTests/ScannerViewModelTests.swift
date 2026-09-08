import XCTest
@testable import Shrunk

@MainActor
final class ScannerViewModelTests: XCTestCase {
    func test_canonicalBarcode_zeroPadsEightDigitEAN() {
        XCTAssertEqual(
            ScannerViewModel.canonicalBarcode(from: "96385074"),
            "0000096385074"
        )
    }

    func test_canonicalBarcode_zeroPadsTwelveDigitUPC() {
        XCTAssertEqual(
            ScannerViewModel.canonicalBarcode(from: "052000135138"),
            "0052000135138"
        )
    }

    func test_canonicalBarcode_keepsThirteenDigitEAN() {
        XCTAssertEqual(
            ScannerViewModel.canonicalBarcode(from: "0052000135138"),
            "0052000135138"
        )
    }

    func test_canonicalBarcode_acceptsSupportedLeadingZeroGTIN14() {
        XCTAssertEqual(
            ScannerViewModel.canonicalBarcode(from: "00052000135138"),
            "0052000135138"
        )
    }

    func test_canonicalBarcode_acceptsHumanReadableSeparators() {
        XCTAssertEqual(
            ScannerViewModel.canonicalBarcode(from: "0 52000-13513 8"),
            "0052000135138"
        )
    }

    func test_canonicalBarcode_rejectsUnsupportedInput() {
        XCTAssertNil(ScannerViewModel.canonicalBarcode(from: ""))
        XCTAssertNil(ScannerViewModel.canonicalBarcode(from: "12345678901"))
        XCTAssertNil(ScannerViewModel.canonicalBarcode(from: "10520001351380"))
        XCTAssertNil(ScannerViewModel.canonicalBarcode(from: "00520001351A8"))
    }

    func test_canonicalBarcode_rejectsInvalidCheckDigit() {
        XCTAssertNil(ScannerViewModel.canonicalBarcode(from: "052000135139"))
        XCTAssertNil(ScannerViewModel.canonicalBarcode(from: "0052000135139"))
    }

    func test_handle_presentsCanonicalBarcodeAndAddsItToRecents() throws {
        let suiteName = "ScannerViewModelTests.\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { storage.removePersistentDomain(forName: suiteName) }
        let viewModel = ScannerViewModel(storage: storage)
        let barcode = try XCTUnwrap(
            ScannerViewModel.canonicalBarcode(from: "052000135138")
        )

        viewModel.handle(barcode: barcode)

        XCTAssertEqual(viewModel.presentedBarcode, "0052000135138")
        XCTAssertEqual(viewModel.recentBarcodes, ["0052000135138"])
    }
}
