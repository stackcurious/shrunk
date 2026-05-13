import Foundation
import Combine

@MainActor
final class ScannerViewModel: ObservableObject {
    @Published var recentBarcodes: [String] = []
    @Published var presentedBarcode: String?
    @Published var lookupError: String?

    private let storage: UserDefaults
    private let recentKey = "shrunk.recent_barcodes"
    private let maxRecent = 5

    init(storage: UserDefaults = .standard) {
        self.storage = storage
        if let stored = storage.array(forKey: recentKey) as? [String] {
            recentBarcodes = stored
        }
    }

    func handle(barcode: String) {
        presentedBarcode = barcode
        addRecent(barcode)
    }

    func clearPresentation() {
        presentedBarcode = nil
    }

    private func addRecent(_ code: String) {
        var list = recentBarcodes
        list.removeAll { $0 == code }
        list.insert(code, at: 0)
        if list.count > maxRecent {
            list = Array(list.prefix(maxRecent))
        }
        recentBarcodes = list
        storage.set(list, forKey: recentKey)
    }
}

/// Identifiable wrapper so a String barcode can drive `.sheet(item:)`.
struct ScannedBarcode: Identifiable, Hashable {
    let id: String
}
