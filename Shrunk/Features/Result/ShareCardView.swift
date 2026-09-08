import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Renderer

enum ShareCardRenderer {
    /// Card is rendered at 3× the spec's design size (390 × 260) so it stays
    /// crisp when re-shared as a screenshot in iMessage/WhatsApp.
    static let designSize = CGSize(width: 390, height: 260)
    static let renderScale: CGFloat = 3
    static var renderSize: CGSize {
        CGSize(width: designSize.width * renderScale, height: designSize.height * renderScale)
    }

    /// Whether this record carries a Then→Now claim we stand behind, and so
    /// whether there is anything to share at all.
    ///
    /// Deliberately the same predicate as `ResultView.comparisonRow`'s gate:
    /// the screen and the shareable PNG must not disagree. `.insufficientData`
    /// records can *have* a `previousSize` — the zero-quantity guard and the
    /// cross-source plausibility clamp both keep one — and drawing it would
    /// put "from 0ml → 946.4ml" into an image that leaves the app under a
    /// screen that says "No shrink on record" (review residual 1).
    ///
    /// `.unchanged` is unreachable from `ShrinkDetector.analyze` today, but
    /// spec §2 lists Share on the unchanged/grew row, so this asks "is the
    /// verdict real" rather than hard-coding the reachable cases.
    static func canShare(record: ShrinkRecord) -> Bool {
        record.verdict != .insufficientData
            && record.previousSize != nil
            && record.currentSize != nil
    }

    static func render(record: ShrinkRecord, product: ShrunkProduct) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: renderSize, format: format)

        return renderer.image { context in
            let ctx = context.cgContext
            ctx.scaleBy(x: renderScale, y: renderScale)
            draw(record: record, product: product, in: CGRect(origin: .zero, size: designSize))
        }
    }

    /// The card is always drawn on white — it is a PNG that leaves the app, so
    /// it can't adopt the viewer's appearance. Semantic colours are therefore
    /// resolved against a light trait collection explicitly: `UIColor.label`
    /// alone follows `UITraitCollection.current`, which renders near-white
    /// label text on the white card when the device is in dark mode.
    private static let lightTraits = UITraitCollection(userInterfaceStyle: .light)

    private static func draw(record: ShrinkRecord, product: ShrunkProduct, in rect: CGRect) {
        let red    = UIColor(Color.shrunkRed).resolvedColor(with: lightTraits)
        let ink    = UIColor.label.resolvedColor(with: lightTraits)
        let smoke  = UIColor.secondaryLabel.resolvedColor(with: lightTraits)
        let border = UIColor.separator.resolvedColor(with: lightTraits)

        // Background
        UIColor.white.setFill()
        UIRectFill(rect)

        // Red top stripe
        red.setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: rect.width, height: 8))

        // Product name (top-left, large bold) + brand (right, small gray)
        let topY: CGFloat = 22
        let topPad: CGFloat = 20
        let nameRect = CGRect(x: topPad, y: topY, width: rect.width * 0.62, height: 44)
        product.name.draw(
            in: nameRect,
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 18, weight: .bold),
                .foregroundColor: ink
            ]
        )

        let brand = product.brand.isEmpty ? product.category : product.brand
        let brandSize = (brand as NSString).size(withAttributes: [
            .font: UIFont.systemFont(ofSize: 13, weight: .medium)
        ])
        let brandRect = CGRect(
            x: rect.width - topPad - brandSize.width,
            y: topY + 4,
            width: brandSize.width,
            height: 22
        )
        brand.draw(
            in: brandRect,
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: smoke
            ]
        )

        // Divider 1
        drawDivider(y: 78, color: border, in: rect)

        // Big number block (left)
        let bigNumber = record.shrinkPercent.formattedPercentChange(decimals: 1)
        let bigFont = UIFont.monospacedDigitSystemFont(ofSize: 44, weight: .bold)
        bigNumber.draw(
            at: CGPoint(x: topPad, y: 92),
            withAttributes: [
                .font: bigFont,
                .foregroundColor: red
            ]
        )

        let leftLabel = labelFor(verdict: record.verdict)
        leftLabel.draw(
            at: CGPoint(x: topPad, y: 140),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: smoke
            ]
        )

        // "They took: N unit" + "from X → Y" (right column)
        let rightX = rect.width / 2 + 12
        let comparable = canShare(record: record)
        let tookString: String = {
            if comparable, let prev = record.previousSize, let curr = record.currentSize {
                let diff = abs(prev.quantity - curr.quantity)
                return "They took: \(Self.compact(diff)) \(curr.unit)"
            }
            return "Tracked by Shrunk"
        }()
        tookString.draw(
            at: CGPoint(x: rightX, y: 100),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: smoke
            ]
        )

        let fromTo: String = {
            if comparable, let prev = record.previousSize, let curr = record.currentSize {
                return "from \(Self.compact(prev.quantity))\(prev.unit) → \(Self.compact(curr.quantity))\(curr.unit)"
            }
            return "first scan"
        }()
        fromTo.draw(
            at: CGPoint(x: rightX, y: 120),
            withAttributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 18, weight: .semibold),
                .foregroundColor: ink
            ]
        )

        // Divider 2
        drawDivider(y: 168, color: border, in: rect)

        // Cost-per-oz line (or product line if no historical price)
        let costLineY: CGFloat = 184
        if let then = record.costPerUnitThen, let now = record.costPerUnitNow, then > 0 {
            let pct = ((now - then) / then) * 100
            let direction = pct >= 0 ? "more" : "less"
            let line = "Then: \(then.formattedCostPerUnit())  →  Now: \(now.formattedCostPerUnit())  (\(abs(pct).formattedPercent(decimals: 1)) \(direction))"
            line.draw(
                at: CGPoint(x: topPad, y: costLineY),
                withAttributes: [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: ink
                ]
            )
            if record.priceIsFromStoreSnapshot {
                drawAttribution(smoke: smoke, topPad: topPad)
            }
        } else if let now = record.costPerUnitNow {
            let denominator: String
            switch record.currentSize?.unitKind {
            case "volume": denominator = "per fl oz"
            case "count": denominator = "per item"
            default: denominator = "per oz"
            }
            "Now: \(now.formattedCostPerUnit()) \(denominator)".draw(
                at: CGPoint(x: topPad, y: costLineY),
                withAttributes: [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: ink
                ]
            )
            if record.priceIsFromStoreSnapshot {
                drawAttribution(smoke: smoke, topPad: topPad)
            }
        } else {
            "Caught with Shrunk".draw(
                at: CGPoint(x: topPad, y: costLineY),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: smoke
                ]
            )
        }

        // Bottom branding
        let footerY: CGFloat = 220
        let logo = "SHRUNK"
        logo.draw(
            at: CGPoint(x: topPad, y: footerY),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: red
            ]
        )

        let url = "stackcurious.com/shrunk"
        let urlSize = (url as NSString).size(withAttributes: [
            .font: UIFont.systemFont(ofSize: 12, weight: .medium)
        ])
        url.draw(
            at: CGPoint(x: rect.width - topPad - urlSize.width, y: footerY + 1),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: smoke
            ]
        )
    }

    private static func drawDivider(y: CGFloat, color: UIColor, in rect: CGRect) {
        color.setFill()
        UIRectFill(CGRect(x: 20, y: y, width: rect.width - 40, height: 0.6))
    }

    /// This image is explicitly designed to leave the app, so the Kroger
    /// price it just drew must carry the same attribution every other surface
    /// does (spec §9, Phase 3 review I6).
    private static func drawAttribution(smoke: UIColor, topPad: CGFloat) {
        LivePrice.attribution.draw(
            at: CGPoint(x: topPad, y: 202),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: smoke
            ]
        )
    }

    private static func compact(_ value: Double) -> String {
        if value == value.rounded() {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }

    private static func labelFor(verdict: ShrinkRecord.ShrinkVerdict) -> String {
        switch verdict {
        case .significantShrink: return "Shrink"
        case .moderateShrink:    return "Shrink"
        case .minorShrink:       return "Shrink"
        case .unchanged:         return "Unchanged"
        case .grew:              return "Grew"
        case .insufficientData:  return "Tracked"
        }
    }
}

// MARK: - Transferable wrapper

struct ShareableShareCard: Transferable {
    let image: UIImage
    let caption: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            guard let data = item.image.pngData() else {
                throw CocoaError(.fileWriteUnknown)
            }
            return data
        }
    }
}

// MARK: - Preview view

struct ShareCardView: View {
    let record: ShrinkRecord
    let product: ShrunkProduct

    @State private var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(.horizontal, 20)

                    ShareLink(
                        item: ShareableShareCard(image: image, caption: caption),
                        preview: SharePreview(caption, image: Image(uiImage: image))
                    ) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.horizontal, 20)
                } else {
                    ProgressView()
                }
                Spacer()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .task {
            image = ShareCardRenderer.render(record: record, product: product)
        }
    }

    private var caption: String {
        switch record.verdict {
        case .significantShrink, .moderateShrink, .minorShrink:
            return "\(product.name) shrunk \(abs(record.shrinkPercent).formattedPercent()). Caught with Shrunk."
        case .unchanged:
            return "\(product.name) — still the same size. Verified with Shrunk."
        case .grew:
            return "\(product.name) actually grew \(abs(record.shrinkPercent).formattedPercent()). Tracked with Shrunk."
        case .insufficientData:
            return "Tracking \(product.name) with Shrunk."
        }
    }
}
