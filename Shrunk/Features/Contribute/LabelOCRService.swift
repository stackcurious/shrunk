import Foundation
import Vision
import CoreGraphics

struct OCRLine: Equatable {
    let text: String
    /// Vision's confidence for this line's top candidate, 0...1.
    let confidence: Double
}

enum LabelOCRError: LocalizedError {
    case recognitionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .recognitionFailed(let error):
            return "Couldn't read the label. (\(error.localizedDescription))"
        }
    }
}

protocol LabelTextRecognizing: Sendable {
    func recognizeText(in image: CGImage) async throws -> [OCRLine]
}

/// Vision text recognition tuned for package labels.
///
/// `usesLanguageCorrection` is deliberately off: correction rewrites "12 OZ"
/// into dictionary words and destroys the exact net-content line we parse.
/// The request is synchronous, so this stays a plain non-isolated async method —
/// callers on `@MainActor` hop off the main thread automatically.
final class LabelOCRService: LabelTextRecognizing {

    func recognizeText(in image: CGImage) async throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false

        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            throw LabelOCRError.recognitionFailed(error)
        }

        let observations = request.results ?? []
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRLine(text: candidate.string, confidence: Double(candidate.confidence))
        }
    }
}
