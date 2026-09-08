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

    /// Canonical form shared by the app and Worker: a 13-digit GTIN. Manual
    /// entry accepts EAN-8, the 12-digit UPC printed beneath most US barcodes, an
    /// already-canonical 13-digit EAN, or the Worker's supported 14-digit form
    /// (a leading zero followed by an EAN-13). Spaces and hyphens are harmless
    /// paste/typing separators; other characters are rejected rather than
    /// silently turning arbitrary text into a lookup.
    nonisolated static func canonicalBarcode(from raw: String) -> String? {
        let compact = raw.filter { !$0.isWhitespace && $0 != "-" }
        guard !compact.isEmpty, compact.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }

        let canonical: String
        switch compact.count {
        case 8:
            canonical = "00000" + compact
        case 12:
            canonical = "0" + compact
        case 13:
            canonical = compact
        case 14 where compact.first == "0":
            canonical = String(compact.dropFirst())
        default:
            return nil
        }

        guard hasValidCheckDigit(canonical) else { return nil }
        return canonical
    }

    /// GS1 modulo-10 check for the canonical 13-digit representation.
    nonisolated private static func hasValidCheckDigit(_ gtin: String) -> Bool {
        let digits = gtin.compactMap(\.wholeNumberValue)
        guard digits.count == 13, let supplied = digits.last else { return false }
        let body = digits.dropLast()
        let sum = body.reversed().enumerated().reduce(0) { total, pair in
            total + pair.element * (pair.offset.isMultiple(of: 2) ? 3 : 1)
        }
        return (10 - sum % 10) % 10 == supplied
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
