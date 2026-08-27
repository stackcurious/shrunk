import XCTest
@testable import Shrunk

/// I2 — UPC-E arrives from AVFoundation as the raw 8-digit compressed code,
/// not expanded to UPC-A the way UPC-A itself is already reported as
/// `.ean13`. `expandUPCEToGTIN13` is the pure, testable half of that fix;
/// wiring it into the `AVCaptureMetadataOutputObjectsDelegate` callback isn't
/// exercised here since that requires a live capture session.
///
/// Digits are named N (number system) D1 D2 D3 D4 D5 D6 C (check digit); the
/// GS1 zero-suppression table is keyed on D6. Each branch below is exercised
/// with a synthetic 8-digit input built to land in that branch — only
/// `04252614` is an independently-verifiable real-world UPC-E/UPC-A pair.
final class BarcodeProcessorTests: XCTestCase {

    func test_expandUPCEToGTIN13_knownConversion() {
        // A widely-cited real-world UPC-E/UPC-A pair (D6 = 1, the "0,1,2"
        // branch): 042100005264 is the UPC-A a barcode scanner shows for
        // UPC-E 04252614.
        XCTAssertEqual(BarcodeProcessor.expandUPCEToGTIN13("04252614"), "0042100005264")
    }

    func test_expandUPCEToGTIN13_lastDigitZeroOneTwoBranch() {
        // D6 = 2 -> manufacturer = N D1 D2 D6 0000, product = D3 D4 D5.
        // N=0 D1=1 D2=2 D3=3 D4=4 D5=5 D6=2 C=7 -> 0 1 2 2 0000 3 4 5 7.
        XCTAssertEqual(BarcodeProcessor.expandUPCEToGTIN13("01234527"), "0012200003457")
    }

    func test_expandUPCEToGTIN13_lastDigitThreeBranch() {
        // D6 = 3 -> manufacturer = N D1 D2 D3 00000, product = D4 D5.
        // N=0 D1=1 D2=2 D3=3 D4=4 D5=5 D6=3 C=7 -> 0 1 2 3 00000 4 5 7.
        XCTAssertEqual(BarcodeProcessor.expandUPCEToGTIN13("01234537"), "0012300000457")
    }

    func test_expandUPCEToGTIN13_lastDigitFourBranch() {
        // D6 = 4 -> manufacturer = N D1 D2 D3 D4 00000, product = D5.
        // N=0 D1=1 D2=2 D3=3 D4=4 D5=5 D6=4 C=7 -> 0 1 2 3 4 00000 5 7.
        XCTAssertEqual(BarcodeProcessor.expandUPCEToGTIN13("01234547"), "0012340000057")
    }

    func test_expandUPCEToGTIN13_lastDigitFiveToNineBranch() {
        // D6 = 5..9 -> manufacturer = N D1 D2 D3 D4 D5 0000, product = D6.
        // N=0 D1=1 D2=2 D3=3 D4=4 D5=5 D6=6 C=7 -> 0 1 2 3 4 5 0000 6 7.
        XCTAssertEqual(BarcodeProcessor.expandUPCEToGTIN13("01234567"), "0012345000067")
    }

    func test_expandUPCEToGTIN13_producesAGTIN13ThatNormalizeGTINWouldAccept() throws {
        // The whole point of the fix: the result must be exactly 13 digits,
        // the form the Worker's `normalizeGTIN` returns as-is (mirror
        // `backend/src/gtin.ts`).
        let expanded = try XCTUnwrap(BarcodeProcessor.expandUPCEToGTIN13("04252614"))
        XCTAssertEqual(expanded.count, 13)
        XCTAssertTrue(expanded.allSatisfy(\.isNumber))
    }

    func test_expandUPCEToGTIN13_rejectsWrongLength() {
        XCTAssertNil(BarcodeProcessor.expandUPCEToGTIN13("1234567"))    // 7 digits
        XCTAssertNil(BarcodeProcessor.expandUPCEToGTIN13("123456789"))  // 9 digits
    }

    func test_expandUPCEToGTIN13_rejectsNonDigits() {
        XCTAssertNil(BarcodeProcessor.expandUPCEToGTIN13("0425261X"))
    }

    func test_expandUPCEToGTIN13_rejectsInvalidNumberSystemDigit() {
        // Only 0 and 1 are valid UPC-E number system digits.
        XCTAssertNil(BarcodeProcessor.expandUPCEToGTIN13("54252614"))
    }
}
