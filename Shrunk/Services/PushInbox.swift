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
    /// A `UNUserNotificationCenterDelegate` callback can fire before that
    /// assignment happens (cold launch from a tap) — anything recorded while
    /// `container` is still nil is buffered in `pendingRecords` and replayed
    /// here the moment a container shows up, instead of being lost.
    @ObservationIgnored var container: ModelContainer? {
        didSet {
            guard container != nil, !pendingRecords.isEmpty else { return }
            let replay = pendingRecords
            pendingRecords.removeAll()
            replay.forEach { record(userInfo: $0) }
        }
    }

    /// Barcode a tapped push asked us to open; `RootView` consumes it.
    var pendingBarcode: String?

    /// iOS can hand us the same push twice — once to wake us in the background,
    /// once when the user taps it. Keyed on `kind|barcode|productName|message`
    /// (the payload), not the delivery, so a re-delivery is a no-op.
    @ObservationIgnored private var seen = Set<String>()

    /// Pushes recorded before `container` was assigned; see `container` above.
    @ObservationIgnored private var pendingRecords: [[AnyHashable: Any]] = []

    private init() {}

    @discardableResult
    func record(userInfo: [AnyHashable: Any]) -> ShrinkAlert? {
        guard let alert = ShrinkAlert.from(pushUserInfo: userInfo) else { return nil }
        let key = "\(alert.kindRaw)|\(alert.barcode)|\(alert.productName)|\(alert.message ?? "")"
        guard !seen.contains(key) else { return nil }

        // No container yet: buffer instead of marking `seen`, so neither this
        // push nor a later delivery of it is dropped once one shows up.
        guard let container else {
            pendingRecords.append(userInfo)
            return nil
        }

        let context = ModelContext(container)
        context.insert(alert)
        do {
            try context.save()
        } catch {
            return nil
        }
        // Only mark seen once the write actually landed.
        seen.insert(key)
        return alert
    }

    /// The user tapped a push. Digest pushes carry no product.
    func open(userInfo: [AnyHashable: Any]) {
        guard let gtin = userInfo["gtin"] as? String, !gtin.isEmpty else { return }
        pendingBarcode = gtin
    }

    /// Test seam: clears the per-process dedup window and any buffered pushes.
    func resetDeduplication() {
        seen.removeAll()
        pendingRecords.removeAll()
    }
}
