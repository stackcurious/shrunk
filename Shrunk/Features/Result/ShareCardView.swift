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

    private static func draw(record: ShrinkRecord, product: ShrunkProduct, in rect: CGRect) {
        let red    = UIColor(Color.shrunkRed)
        let ink    = UIColor(Color.ink)
        let smoke  = UIColor(Color.smoke)
        let border = UIColor(Color.border)

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
        let bigFont = UIFont.monospacedSystemFont(ofSize: 44, weight: .heavy)
        bigNumber.draw(
            at: CGPoint(x: topPad, y: 92),
            withAttributes: [
                .font: bigFont,
                .foregroundColor: red
            ]
        )

        let leftLabel = labelFor(verdict: record.verdict).uppercased()
        leftLabel.draw(
            at: CGPoint(x: topPad, y: 138),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 11, weight: .heavy),
                .foregroundColor: smoke,
                .kern: 0.6
            ]
        )

        // "They took: N unit" + "from X → Y" (right column)
        let rightX = rect.width / 2 + 12
        let tookString: String = {
            if let prev = record.previousSize, let curr = record.currentSize {
                let diff = abs(prev.quantity - curr.quantity)
                return "THEY TOOK: \(Self.compact(diff)) \(curr.unit)"
            }
            return "TRACKED BY SHRUNK"
        }()
        tookString.draw(
            at: CGPoint(x: rightX, y: 100),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 11, weight: .heavy),
                .foregroundColor: smoke,
                .kern: 0.6
            ]
        )

        let fromTo: String = {
            if let prev = record.previousSize, let curr = record.currentSize {
                return "from \(Self.compact(prev.quantity))\(prev.unit) → \(Self.compact(curr.quantity))\(curr.unit)"
            }
            return "first scan"
        }()
        fromTo.draw(
            at: CGPoint(x: rightX, y: 118),
            withAttributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 18, weight: .bold),
                .foregroundColor: ink
            ]
        )

        // Divider 2
        drawDivider(y: 168, color: border, in: rect)

        // Cost-per-oz line (or product line if no historical price)
        let costLineY: CGFloat = 184
        if let then = record.costPerUnitThen, let now = record.costPerUnitNow, then > 0 {
            let pct = ((now - then) / then) * 100
            let line = "Then: \(then.formattedCostPerUnit())  →  Now: \(now.formattedCostPerUnit())  (\(pct.formattedPercentChange(decimals: 1)) more)"
            line.draw(
                at: CGPoint(x: topPad, y: costLineY),
                withAttributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: ink
                ]
            )
        } else if let now = record.costPerUnitNow {
            "Now: \(now.formattedCostPerUnit()) per ounce".draw(
                at: CGPoint(x: topPad, y: costLineY),
                withAttributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: ink
                ]
            )
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
                .font: UIFont.systemFont(ofSize: 13, weight: .heavy),
                .foregroundColor: red,
                .kern: 1.4
            ]
        )

        let url = "shrunk.app"
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
            VStack(spacing: ShrunkTheme.Spacing.lg) {
                Spacer()
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 6)
                        .padding(.horizontal, ShrunkTheme.Spacing.lg)

                    ShareLink(
                        item: ShareableShareCard(image: image, caption: caption),
                        preview: SharePreview(caption, image: Image(uiImage: image))
                    ) {
                        HStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 16, weight: .semibold))
                            Text("Share")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Color.shrunkRed)
                        .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.md, style: .continuous))
                    }
                    .padding(.horizontal, ShrunkTheme.Spacing.lg)
                } else {
                    ProgressView()
                }
                Spacer()
            }
            .background(Color.mist)
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.shrunkRed)
                        .fontWeight(.semibold)
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
