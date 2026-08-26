import Foundation
import CoreGraphics

/// Drives the contribution flow: still capture → OCR → confirm → upload.
@MainActor
final class ContributeViewModel: ObservableObject {

    enum Step: Equatable {
        case capture
        case reading
        case confirm
        case submitting
        case finished(SubmissionResult)
        case failed(String)
    }

    @Published private(set) var step: Step = .capture
    @Published var quantityText: String = ""
    @Published var unitKind: UnitKind = .mass
    /// The label line the quantity came from. Sent as `raw_text` and shown in
    /// the confirm sheet so the shopper can see what we read.
    @Published private(set) var sourceLine: String = ""

    let gtin: String

    private let deviceId: String
    private let ocr: any LabelTextRecognizing
    private let api: any ObservationSubmitting

    private var photoJPEG: Data?
    private var ocrConfidence: Double = 0

    init(
        gtin: String,
        deviceId: String = DeviceIdentity.current,
        ocr: any LabelTextRecognizing = LabelOCRService(),
        api: any ObservationSubmitting = ShrunkAPIClient.shared
    ) {
        self.gtin = gtin
        self.deviceId = deviceId
        self.ocr = ocr
        self.api = api
    }

    var canSubmit: Bool {
        guard let value = Double(quantityText) else { return false }
        return value > 0
    }

    /// Camera hand-off: the still frame feeds Vision, the JPEG rides along in
    /// case the gate holds the row for review.
    func handleCapture(image: CGImage, jpegData: Data) async {
        photoJPEG = jpegData
        step = .reading

        let lines: [OCRLine]
        do {
            lines = try await ocr.recognizeText(in: image)
        } catch {
            beginManualEntry()
            return
        }

        guard let match = NetContentParser.firstNetContent(in: lines.map(\.text)) else {
            beginManualEntry()
            return
        }

        ocrConfidence = lines[match.lineIndex].confidence
        sourceLine = match.line
        quantityText = Self.format(match.parsed.quantity)
        unitKind = match.parsed.unitKind
        step = .confirm
    }

    /// Spec §8: "OCR finds no net-content line: manual entry sheet with quantity + unit."
    func beginManualEntry() {
        ocrConfidence = 0
        sourceLine = ""
        quantityText = ""
        unitKind = .mass
        step = .confirm
    }

    func submit() async {
        guard let quantity = Double(quantityText), quantity > 0 else { return }
        step = .submitting
        do {
            let result = try await api.submitObservation(
                gtin: gtin,
                quantity: quantity,
                unitKind: unitKind,
                rawText: sourceLine,
                ocrConfidence: ocrConfidence,
                deviceId: deviceId,
                photoJPEG: photoJPEG
            )
            step = .finished(result)
        } catch ShrunkError.network(_) {
            // Spec §8, verbatim.
            step = .failed("Couldn't reach Shrunk — check connection.")
        } catch let error as ShrunkError {
            step = .failed(error.errorDescription ?? "Couldn't reach Shrunk — check connection.")
        } catch {
            step = .failed(error.localizedDescription)
        }
    }

    static func toastMessage(for result: SubmissionResult) -> String {
        switch result.status {
        case .accepted: return "Added — thanks for the label."
        case .pending:  return "Thanks — we'll review your photo."
        }
    }

    /// Up to three decimals with the trailing zeros trimmed, so an unedited
    /// 340.194 g submits at full precision but 500 mL reads as "500".
    static func format(_ quantity: Double) -> String {
        var text = String(format: "%.3f", quantity)
        while text.contains("."), text.hasSuffix("0") || text.hasSuffix(".") {
            text.removeLast()
        }
        return text
    }
}
