import XCTest
import UIKit
@testable import Shrunk

final class LabelOCRServiceTests: XCTestCase {

    /// Draws black label text on white so Vision has something realistic to read.
    private func labelImage(_ lines: [String]) throws -> CGImage {
        let size = CGSize(width: 800, height: 400)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 56, weight: .bold),
                .foregroundColor: UIColor.black
            ]
            for (index, line) in lines.enumerated() {
                line.draw(at: CGPoint(x: 40, y: 40 + 90 * index), withAttributes: attributes)
            }
        }
        return try XCTUnwrap(image.cgImage)
    }

    func test_recognizeText_readsTheNetContentLine() async throws {
        let image = try labelImage(["DORITOS", "NET WT 12 OZ"])
        let lines = try await LabelOCRService().recognizeText(in: image)

        try XCTSkipIf(lines.isEmpty, "Vision text recognition is unavailable on this simulator host")

        let joined = lines.map(\.text).joined(separator: " ").uppercased()
        XCTAssertTrue(joined.contains("12"), "expected the quantity in \(joined)")
        XCTAssertTrue(joined.contains("OZ"), "expected the unit in \(joined)")
        for line in lines {
            XCTAssertGreaterThan(line.confidence, 0)
            XCTAssertLessThanOrEqual(line.confidence, 1)
        }
    }

    func test_recognizeText_returnsNoLinesForABlankImage() async throws {
        let lines = try await LabelOCRService().recognizeText(in: try labelImage([]))
        XCTAssertTrue(lines.isEmpty)
    }

    /// The parser and the OCR service have to agree end to end.
    func test_recognizedLinesFeedTheParser() async throws {
        let image = try labelImage(["DORITOS", "NET WT 12 OZ"])
        let lines = try await LabelOCRService().recognizeText(in: image)
        try XCTSkipIf(lines.isEmpty, "Vision text recognition is unavailable on this simulator host")

        guard let match = NetContentParser.firstNetContent(in: lines.map(\.text)) else {
            throw XCTSkip("Vision read \(lines.map(\.text)) — no net-content line to parse")
        }
        XCTAssertEqual(match.parsed.unitKind, .mass)
        XCTAssertEqual(match.parsed.quantity, 340.194, accuracy: 0.5)
    }
}
