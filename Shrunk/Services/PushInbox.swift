import Foundation
import SwiftData
import Observation

/// Everything that arrives by push lands here: the alert is written into the
/// Alerts feed, and a tapped alert leaves a barcode for `RootView` to open
/// (spec §7).
@MainActor
@Observable
final class PushInbox {
    static let shared = PushInbox()

    /// Set by `ShrunkApp.init` so a push can be written from the app delegate.
    @ObservationIgnored var container: ModelContainer?

    /// Barcode a tapped push asked us to open; `RootView` consumes it.
    var pendingBarcode: String?

    /// iOS can hand us the same push twice — once to wake us in the background,
    /// once when the user taps it. The key is the payload, not the delivery.
    @ObservationIgnored private var seen = Set<String>()

    private init() {}

    @discardableResult
    func record(userInfo: [AnyHashable: Any]) -> ShrinkAlert? {
        guard let alert = ShrinkAlert.from(pushUserInfo: userInfo) else { return nil }
        let key = "\(alert.kindRaw)|\(alert.barcode)|\(alert.productName)|\(alert.message ?? "")"
        guard !seen.contains(key) else { return nil }
        seen.insert(key)

        guard let container else { return nil }
        let context = ModelContext(container)
        context.insert(alert)
        try? context.save()
        return alert
    }

    /// The user tapped a push. Digest pushes carry no product.
    func open(userInfo: [AnyHashable: Any]) {
        guard let gtin = userInfo["gtin"] as? String, !gtin.isEmpty else { return }
        pendingBarcode = gtin
    }

    /// Test seam: clears the per-process dedup window.
    func resetDeduplication() {
        seen.removeAll()
    }
}
