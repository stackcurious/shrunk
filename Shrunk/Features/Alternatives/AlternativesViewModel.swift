import Foundation

@MainActor
final class AlternativesViewModel: ObservableObject {
    @Published var presentedBarcode: String?
    @Published var showPaywall: Bool = false

    let sourceProduct: ShrunkProduct
    let sourceRecord: ShrinkRecord
    let alternatives: [Alternative]

    private let freeVisibleCount = 2

    init(product: ShrunkProduct, record: ShrinkRecord, alternatives: [Alternative]) {
        self.sourceProduct = product
        self.sourceRecord = record
        self.alternatives = alternatives
    }

    func canView(_ alternative: Alternative, isPro: Bool) -> Bool {
        if isPro { return true }
        guard let index = alternatives.firstIndex(where: { $0.id == alternative.id }) else {
            return false
        }
        return index < freeVisibleCount
    }

    func handleTap(_ alternative: Alternative, isPro: Bool) {
        if canView(alternative, isPro: isPro) {
            presentedBarcode = alternative.id
        } else {
            showPaywall = true
        }
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
