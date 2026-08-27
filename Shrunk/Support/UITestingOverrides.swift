import Foundation
import QuartzCore
import SwiftData
import UIKit

/// Screenshot-mode overrides for `ShrunkUITests`.
///
/// Everything here is inert unless the process was launched with `-ui-testing`,
/// and in a Release build `isActive` is a compile-time `false`, so every call
/// site folds away. Nothing in this file changes production behaviour.
///
/// What it does, and why each one is needed on a simulator:
///  - **Pro entitlement** — StoreKit testing is unavailable here (and hangs on
///    this Mac), so `StoreKitService` reports Pro (or, with `-ui-testing-pro 0`,
///    free) instead of asking the App Store.
///  - **Store** — `-ui-testing-store <locationId>` / `-ui-testing-store-name`
///    write the same two `UserDefaults` keys the store picker writes, so the
///    live-price panel queries a real Kroger store. Prices themselves are never
///    faked: they come from `/v1/kroger/product` on the production Worker.
///  - **Alerts** — the Alerts feed is filled by push, which a simulator cannot
///    receive. Seeds fixture rows drawn from real curated cases.
///  - **Contribution draft** — the confirm sheet is reached through the camera.
///    Seeds it by running the *real* `NetContentParser` over a real label line.
///  - **Camera** — no camera exists on a simulator, so the two capture
///    controllers report authorized and the preview layer paints a neutral
///    backdrop. The scanner/label chrome above it is the real thing.
enum UITestingOverrides {

    #if DEBUG
    static let isActive: Bool = ProcessInfo.processInfo.arguments.contains("-ui-testing")
    #else
    static let isActive: Bool = false
    #endif

    // MARK: - Launch arguments

    /// `-flag value`, or nil when the flag is absent or trails the list.
    private static func value(for flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: flag) else { return nil }
        let next = args.index(after: index)
        guard next < args.endIndex else { return nil }
        return args[next]
    }

    /// Pro is on by default in screenshot mode; `-ui-testing-pro 0` turns it
    /// off, which is how the paywall pass reaches the paywall at all.
    static var forcesPro: Bool { isActive && value(for: "-ui-testing-pro") != "0" }

    // MARK: - Fixture content

    /// A real OCR-shaped label line. The confirm sheet's quantity is whatever
    /// `NetContentParser` actually makes of it — never a hand-typed number.
    static let contributionLabelLine = "NET WT 12.5 OZ (354g)"

    /// Seeded so the scanner's RECENT row is populated and the tests have a
    /// deterministic way into a result screen without a camera.
    static var recentBarcodes: [String] {
        ["-ui-testing-recent-a", "-ui-testing-recent-b", "-ui-testing-recent-c"]
            .compactMap { value(for: $0) }
    }

    // MARK: - Defaults

    /// Called first thing in `ShrunkApp.init()`, before any `@AppStorage` read.
    static func prepareDefaults() {
        guard isActive else { return }
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "shrunk.has_completed_onboarding")
        // Start on the tab the shot needs. Launching straight there avoids the
        // window-scheme flip you get by tapping across from the dark scanner,
        // which can leave the tab bar's material mid-transition in a capture.
        defaults.set(Int(value(for: "-ui-testing-tab") ?? "") ?? 0, forKey: "shrunk.selected_tab")
        if let locationId = value(for: "-ui-testing-store") {
            defaults.set(locationId, forKey: StorePickerViewModel.locationIdKey)
        }
        if let storeName = value(for: "-ui-testing-store-name") {
            defaults.set(storeName, forKey: StorePickerViewModel.storeNameKey)
        }
        let recents = recentBarcodes
        if !recents.isEmpty {
            defaults.set(recents, forKey: "shrunk.recent_barcodes")
        }
    }

    // MARK: - SwiftData fixtures

    /// Replaces the alert feed with one `sizeDrop` and one `priceHike` (the two
    /// the store listing asks for) plus one `verifiedCase`, so the feed reads
    /// like a real week. Every figure is copied from `data/trending.json`'s
    /// verified cases — no invented shrink percentages, and no `currentPrice`,
    /// so the savings hero shows no dollar figure it can't back up.
    static func seedFixtures(container: ModelContainer) {
        guard isActive else { return }
        let context = ModelContext(container)
        if let existing = try? context.fetch(FetchDescriptor<ShrinkAlert>()) {
            for alert in existing { context.delete(alert) }
        }

        let now = Date()
        let fixtures: [ShrinkAlert] = [
            ShrinkAlert(
                barcode: "0036000452228",
                productName: "Bounty Select-A-Size Paper Towels",
                brand: "Bounty",
                kind: .sizeDrop,
                previousQuantity: 117,
                previousUnit: "count",
                currentQuantity: 105,
                currentUnit: "count",
                shrinkPercent: -10.3,
                createdAt: now.addingTimeInterval(-3 * 3600),
                isRead: false,
                message: "Bounty Select-A-Size just shrank — 117 → 105 sheets a roll."
            ),
            ShrinkAlert(
                barcode: "0024100762330",
                productName: "Cheez-It Original Family Size",
                brand: "Cheez-It",
                kind: .priceHike,
                shrinkPercent: 0,
                createdAt: now.addingTimeInterval(-27 * 3600),
                isRead: false,
                message: "Cheez-It Original costs more per ounce at your store this week."
            ),
            ShrinkAlert(
                barcode: "7622210449283",
                productName: "Toblerone Milk Chocolate Bar",
                brand: "Toblerone",
                kind: .verifiedCase,
                previousQuantity: 360,
                previousUnit: "g",
                currentQuantity: 150,
                currentUnit: "g",
                shrinkPercent: -58.3,
                createdAt: now.addingTimeInterval(-4 * 24 * 3600),
                isRead: true,
                message: "We published a verified case: Toblerone went 360 g → 150 g."
            )
        ]
        for alert in fixtures { context.insert(alert) }
        try? context.save()
    }

    // MARK: - Camera stand-in

    /// A neutral, slightly-vignetted dark backdrop where the camera feed would
    /// be. Deliberately *not* a product photo: a simulator has no camera, and a
    /// bundled package shot composited under the reticle would misrepresent
    /// what the app actually sees.
    static func installCameraBackdrop(on view: UIView) -> CALayer {
        let gradient = CAGradientLayer()
        gradient.colors = [
            UIColor(white: 0.34, alpha: 1).cgColor,
            UIColor(white: 0.20, alpha: 1).cgColor,
            UIColor(white: 0.11, alpha: 1).cgColor
        ]
        gradient.locations = [0, 0.55, 1]
        gradient.startPoint = CGPoint(x: 0.25, y: 0)
        gradient.endPoint = CGPoint(x: 0.75, y: 1)
        gradient.frame = view.bounds
        view.layer.addSublayer(gradient)
        return gradient
    }
}
