import XCTest
import CoreGraphics
@testable import Shrunk

// MARK: - Stubs

final class StubOCR: LabelTextRecognizing, @unchecked Sendable {
    var lines: [OCRLine] = []
    var error: Error?

    func recognizeText(in image: CGImage) async throws -> [OCRLine] {
        if let error { throw error }
        return lines
    }
}

final class StubSubmitter: ObservationSubmitting, @unchecked Sendable {
    struct Call: Equatable {
        let gtin: String
        let quantity: Double
        let unitKind: UnitKind
        let rawText: String
        let ocrConfidence: Double
        let deviceId: String
        let photoBytes: Int
    }

    private(set) var calls: [Call] = []
    var result = SubmissionResult(status: .accepted, confidence: 0.9, observationId: 42)
    var error: Error?

    func submitObservation(
        gtin: String, quantity: Double, unitKind: UnitKind, rawText: String,
        ocrConfidence: Double, deviceId: String, photoJPEG: Data?
    ) async throws -> SubmissionResult {
        calls.append(Call(
            gtin: gtin, quantity: quantity, unitKind: unitKind, rawText: rawText,
            ocrConfidence: ocrConfidence, deviceId: deviceId, photoBytes: photoJPEG?.count ?? 0
        ))
        if let error { throw error }
        return result
    }
}

// MARK: - Tests

@MainActor
final class ContributeViewModelTests: XCTestCase {

    private let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])

    private func pixel() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try XCTUnwrap(context.makeImage())
    }

    private func makeVM(ocr: StubOCR, api: StubSubmitter) -> ContributeViewModel {
        ContributeViewModel(gtin: "0028400642255", deviceId: "device-1", ocr: ocr, api: api)
    }

    func test_handleCapture_parsesTheNetContentLineIntoTheConfirmStep() async throws {
        let ocr = StubOCR()
        ocr.lines = [
            OCRLine(text: "DORITOS", confidence: 0.99),
            OCRLine(text: "NET WT 12 OZ (340g)", confidence: 0.94),
            OCRLine(text: "INGREDIENTS: CORN", confidence: 0.88)
        ]
        let vm = makeVM(ocr: ocr, api: StubSubmitter())

        await vm.handleCapture(image: try pixel(), jpegData: jpeg)

        XCTAssertEqual(vm.step, .confirm)
        XCTAssertEqual(vm.quantityText, "340.194")
        XCTAssertEqual(vm.unitKind, .mass)
        XCTAssertEqual(vm.sourceLine, "NET WT 12 OZ (340g)")
        XCTAssertTrue(vm.canSubmit)
    }

    func test_handleCapture_withNoNetContentLine_fallsBackToManualEntry() async throws {
        let ocr = StubOCR()
        ocr.lines = [OCRLine(text: "DORITOS", confidence: 0.99), OCRLine(text: "PARTY SIZE", confidence: 0.9)]
        let vm = makeVM(ocr: ocr, api: StubSubmitter())

        await vm.handleCapture(image: try pixel(), jpegData: jpeg)

        XCTAssertEqual(vm.step, .confirm)
        XCTAssertEqual(vm.quantityText, "")
        XCTAssertEqual(vm.sourceLine, "")
        XCTAssertFalse(vm.canSubmit)
    }

    func test_handleCapture_whenOCRThrows_fallsBackToManualEntry() async throws {
        let ocr = StubOCR()
        ocr.error = LabelOCRError.recognitionFailed(URLError(.unknown))
        let vm = makeVM(ocr: ocr, api: StubSubmitter())

        await vm.handleCapture(image: try pixel(), jpegData: jpeg)

        XCTAssertEqual(vm.step, .confirm)
        XCTAssertEqual(vm.quantityText, "")
    }

    func test_submit_sendsTheConfirmedValuesAndThePhoto() async throws {
        let ocr = StubOCR()
        ocr.lines = [OCRLine(text: "NET WT 12 OZ (340g)", confidence: 0.94)]
        let api = StubSubmitter()
        let vm = makeVM(ocr: ocr, api: api)

        await vm.handleCapture(image: try pixel(), jpegData: jpeg)
        await vm.submit()

        XCTAssertEqual(api.calls, [StubSubmitter.Call(
            gtin: "0028400642255", quantity: 340.194, unitKind: .mass,
            rawText: "NET WT 12 OZ (340g)", ocrConfidence: 0.94,
            deviceId: "device-1", photoBytes: 4
        )])
        XCTAssertEqual(vm.step, .finished(SubmissionResult(status: .accepted, confidence: 0.9, observationId: 42)))
    }

    func test_submit_sendsTheEditedQuantityAndUnit() async throws {
        let ocr = StubOCR()
        ocr.lines = [OCRLine(text: "NET WT 12 OZ (340g)", confidence: 0.94)]
        let api = StubSubmitter()
        let vm = makeVM(ocr: ocr, api: api)

        await vm.handleCapture(image: try pixel(), jpegData: jpeg)
        vm.quantityText = "283.5"
        vm.unitKind = .volume
        await vm.submit()

        XCTAssertEqual(api.calls.first?.quantity, 283.5)
        XCTAssertEqual(api.calls.first?.unitKind, .volume)
        // The raw label line is preserved even when the shopper corrects the number.
        XCTAssertEqual(api.calls.first?.rawText, "NET WT 12 OZ (340g)")
    }

    func test_submit_manualEntry_sendsZeroOCRConfidenceAndNoRawText() async throws {
        let api = StubSubmitter()
        let vm = makeVM(ocr: StubOCR(), api: api)

        await vm.handleCapture(image: try pixel(), jpegData: jpeg)
        vm.quantityText = "500"
        vm.unitKind = .volume
        await vm.submit()

        XCTAssertEqual(api.calls.first?.ocrConfidence, 0)
        XCTAssertEqual(api.calls.first?.rawText, "")
        XCTAssertEqual(api.calls.first?.quantity, 500)
    }

    func test_submit_networkFailure_showsTheOfflineCopy() async throws {
        let ocr = StubOCR()
        ocr.lines = [OCRLine(text: "NET WT 12 OZ (340g)", confidence: 0.94)]
        let api = StubSubmitter()
        api.error = ShrunkError.network(URLError(.notConnectedToInternet))
        let vm = makeVM(ocr: ocr, api: api)

        await vm.handleCapture(image: try pixel(), jpegData: jpeg)
        await vm.submit()

        guard case .failed(let message) = vm.step else {
            return XCTFail("expected .failed, got \(vm.step)")
        }
        XCTAssertEqual(message, "Couldn't reach Shrunk — check connection.")
    }

    func test_submit_isARefusedNoOpWithoutAUsableQuantity() async {
        let api = StubSubmitter()
        let vm = makeVM(ocr: StubOCR(), api: api)
        vm.beginManualEntry()

        for text in ["", "0", "-1", "abc"] {
            vm.quantityText = text
            XCTAssertFalse(vm.canSubmit, text)
            await vm.submit()
        }
        XCTAssertTrue(api.calls.isEmpty)
        XCTAssertEqual(vm.step, .confirm)
    }

    func test_toastMessage() {
        XCTAssertEqual(
            ContributeViewModel.toastMessage(for: SubmissionResult(status: .accepted, confidence: 1, observationId: 1)),
            "Added — thanks for the label."
        )
        XCTAssertEqual(
            ContributeViewModel.toastMessage(for: SubmissionResult(status: .pending, confidence: 0.5, observationId: 1)),
            "Thanks — we'll review your photo."
        )
    }

    func test_format_trimsTrailingZerosWithoutLosingPrecision() {
        XCTAssertEqual(ContributeViewModel.format(340.194), "340.194")
        XCTAssertEqual(ContributeViewModel.format(500), "500")
        XCTAssertEqual(ContributeViewModel.format(4258.584), "4258.584")
        XCTAssertEqual(ContributeViewModel.format(73.709), "73.709")
        XCTAssertEqual(ContributeViewModel.format(1360), "1360")
    }
}
