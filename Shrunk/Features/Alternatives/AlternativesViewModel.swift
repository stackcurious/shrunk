import Foundation

@MainActor
final class AlternativesViewModel: ObservableObject {
    @Published var presentedBarcode: String?
    @Published var showPaywall: Bool = false

    let sourceProduct: ShrunkProduct
    let sourceRecord: ShrinkRecord
    let result: AlternativesResult

    init(product: ShrunkProduct, record: ShrinkRecord, result: AlternativesResult) {
        self.sourceProduct = product
        self.sourceRecord = record
        self.result = result
    }

    var alternatives: [Alternative] { result.alternatives }
    var hiddenCount: Int { result.hiddenCount }
    var isCurated: Bool { result.isCurated }

    /// Curated rows are verified cases, not recommendations — say so.
    var title: String { isCurated ? "Verified cases in this category" : "Cheaper at your store" }

    func present(_ alternative: Alternative) {
        presentedBarcode = alternative.id
    }

    func headerCostPerUnitText() -> String {
        guard let curr = sourceRecord.costPerUnitNow else { return sourceProduct.name }
        let sizeStr: String
        if let currentSize = sourceRecord.currentSize {
            sizeStr = currentSize.quantity.formattedQuantity(unit: currentSize.unit)
        } else {
            sizeStr = ""
        }
        return "vs. \(sourceProduct.name) \(sizeStr) · \(curr.formattedCostPerUnit(currency: sourceProduct.currency))"
    }
}
