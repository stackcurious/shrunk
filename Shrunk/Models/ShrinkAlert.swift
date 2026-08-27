import Foundation
import SwiftData

@Model
final class ShrinkAlert {
    @Attribute(.unique) var id: UUID
    var barcode: String
    var productName: String
    var brand: String
    var kindRaw: String
    var previousQuantity: Double?
    var previousUnit: String?
    var currentQuantity: Double?
    var currentUnit: String?
    var shrinkPercent: Double
    /// The observed price at the user's store when this alert was filed
    /// (spec §3.5 — the savings dashboard's per-product input).
    var currentPrice: Double?
    var costDeltaPerUnit: Double?
    var createdAt: Date
    var isRead: Bool
    /// The push body, kept verbatim so the feed shows exactly what we sent.
    var message: String?

    init(
        id: UUID = UUID(),
        barcode: String,
        productName: String,
        brand: String,
        kind: Kind,
        previousQuantity: Double? = nil,
        previousUnit: String? = nil,
        currentQuantity: Double? = nil,
        currentUnit: String? = nil,
        shrinkPercent: Double = 0,
        currentPrice: Double? = nil,
        costDeltaPerUnit: Double? = nil,
        createdAt: Date = Date(),
        isRead: Bool = false,
        message: String? = nil
    ) {
        self.id = id
        self.barcode = barcode
        self.productName = productName
        self.brand = brand
        self.kindRaw = kind.rawValue
        self.previousQuantity = previousQuantity
        self.previousUnit = previousUnit
        self.currentQuantity = currentQuantity
        self.currentUnit = currentUnit
        self.shrinkPercent = shrinkPercent
        self.currentPrice = currentPrice
        self.costDeltaPerUnit = costDeltaPerUnit
        self.createdAt = createdAt
        self.isRead = isRead
        self.message = message
    }

    enum Kind: String, Codable, CaseIterable {
        case newShrink     // confirmed shrinkage just detected on device
        case unconfirmed   // possible change, needs user re-scan
        case stable        // no change since last check
        case sizeDrop      // push: a watched product got smaller (spec §3)
        case priceHike     // push: per-unit price up >= 5% at the user's store
        case verifiedCase  // push: we published a verified case for it
        case digest        // push: the Monday "what shrank this week" summary

        /// Kinds that mean "this really did shrink" — the Confirmed filter.
        var isConfirmedShrink: Bool {
            switch self {
            case .newShrink, .sizeDrop, .verifiedCase: return true
            case .unconfirmed, .stable, .priceHike, .digest: return false
            }
        }
    }

    var kind: Kind { Kind(rawValue: kindRaw) ?? .stable }

    /// What the row says. A push carries its own copy; anything produced on
    /// device falls back to the per-kind wording below.
    var headline: String {
        if let message, !message.isEmpty { return message }
        let label = brand.isEmpty ? productName : brand
        switch kind {
        case .newShrink:
            if let prevQ = previousQuantity, let prevU = previousUnit,
               let currQ = currentQuantity, let currU = currentUnit {
                return "\(label) just shrank — \(prevQ.formattedQuantity(unit: prevU)) → \(currQ.formattedQuantity(unit: currU))"
            }
            return "Confirmed shrink. Tap to see details."
        case .unconfirmed:  return "Possible size change in \(label) — scan to confirm."
        case .stable:       return "\(label) unchanged — still watching."
        case .sizeDrop:     return "\(label) just shrank — tap to see the new size."
        case .priceHike:    return "\(label) costs more per unit at your store."
        case .verifiedCase: return "We published a verified case for \(label)."
        case .digest:       return "Your weekly shrink digest is ready."
        }
    }
}

extension ShrinkAlert {
    static func newShrink(from watched: WatchedProduct, record: ShrinkRecord) -> ShrinkAlert {
        ShrinkAlert(
            barcode: watched.barcode,
            productName: watched.productName,
            brand: watched.brand,
            kind: .newShrink,
            previousQuantity: record.previousSize?.quantity,
            previousUnit: record.previousSize?.unit,
            currentQuantity: record.currentSize?.quantity,
            currentUnit: record.currentSize?.unit,
            shrinkPercent: record.shrinkPercent,
            currentPrice: record.priceNow,
            costDeltaPerUnit: nil
        )
    }

    /// Files from a plain scan, independent of the watchlist (spec §3.5 —
    /// "for each scanned or watched product" — a product doesn't need to be
    /// watched to count). `isRead: true`: a scan is something the user is
    /// already looking at on the result screen, so filing it must not
    /// inflate the Alerts tab's unread badge the way an unseen push would.
    ///
    /// `currentPrice` is carried only when `record.priceIsFromStoreSnapshot`
    /// — i.e. `priceNow` actually came from a Kroger `price_snapshots` entry,
    /// not the `product.currentPrice` fallback (curated Browse cards read
    /// from `trending.json`, an editorial price, never Kroger-observed). The
    /// alert still files and still shows as a confirmed shrink; it just
    /// carries no dollar figure `SavingsLedger` could count as "observed."
    static func newShrink(from product: ShrunkProduct, record: ShrinkRecord) -> ShrinkAlert {
        ShrinkAlert(
            barcode: product.id,
            productName: product.name,
            brand: product.brand,
            kind: .newShrink,
            previousQuantity: record.previousSize?.quantity,
            previousUnit: record.previousSize?.unit,
            currentQuantity: record.currentSize?.quantity,
            currentUnit: record.currentSize?.unit,
            shrinkPercent: record.shrinkPercent,
            currentPrice: record.priceIsFromStoreSnapshot ? record.priceNow : nil,
            costDeltaPerUnit: nil,
            isRead: true
        )
    }

    /// Builds a feed row from a remote-notification payload. `kind` is the
    /// Worker's camelCase alert kind; `gtin` is absent on the weekly digest.
    static func from(pushUserInfo userInfo: [AnyHashable: Any]) -> ShrinkAlert? {
        guard let rawKind = userInfo["kind"] as? String, let kind = Kind(rawValue: rawKind) else { return nil }
        let aps = userInfo["aps"] as? [AnyHashable: Any]
        let alert = aps?["alert"] as? [AnyHashable: Any]
        let title = (alert?["title"] as? String) ?? ""
        let body = (alert?["body"] as? String) ?? ""

        let trimmedName = (userInfo["product_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (trimmedName?.isEmpty == false ? trimmedName : nil) ?? productName(fromPushTitle: title)

        return ShrinkAlert(
            barcode: (userInfo["gtin"] as? String) ?? "",
            productName: name,
            brand: "",
            kind: kind,
            message: body
        )
    }

    /// The Worker templates push titles around the product label (`alerts.ts`
    /// `alertCopy`: `"{label} just shrank"`, `"{label} costs more per unit"`,
    /// `"New verified case: {label}"`). Strip the template so the feed's
    /// product-name line reads just the label instead of the full sentence.
    private static func productName(fromPushTitle title: String) -> String {
        guard !title.isEmpty else { return "Shrunk" }
        let suffixes = [" just shrank", " costs more per unit"]
        for suffix in suffixes where title.hasSuffix(suffix) {
            return String(title.dropLast(suffix.count))
        }
        let prefix = "New verified case: "
        if title.hasPrefix(prefix) { return String(title.dropFirst(prefix.count)) }
        return title
    }

    /// The device-side `BGAppRefresh` check found a live size that disagrees
    /// with the last one we recorded (spec §7).
    ///
    /// Minor #2: `shrinkPercent` is percentage points everywhere else it's
    /// used — `ShrinkRecord.shrinkPercent` (`ShrinkDetector`), `SavingsLedger
    /// .makeEntry`, `AlertRow`, `SavingsDashboardView` — so this multiplies
    /// by 100 to match, rather than storing a bare fraction. (Harmless today
    /// only because `.unconfirmed` is excluded everywhere `shrinkPercent` is
    /// actually read — `Kind.isConfirmedShrink` is false for it — but a
    /// future surface of it would otherwise under-report by 100×.) This is
    /// independent of `ShrunkApp.runWatchlistSweep`'s own, separate fraction
    /// computation for `NotificationPreferences.shouldFire(shrinkPercent:)`,
    /// which is documented there to want 0...1, not points.
    static func unconfirmed(from watched: WatchedProduct, liveQuantity: Double) -> ShrinkAlert {
        ShrinkAlert(
            barcode: watched.barcode,
            productName: watched.productName,
            brand: watched.brand,
            kind: .unconfirmed,
            previousQuantity: watched.lastKnownSize,
            previousUnit: watched.lastKnownUnit,
            currentQuantity: liveQuantity,
            currentUnit: watched.lastKnownUnit,
            shrinkPercent: watched.lastKnownSize > 0
                ? (liveQuantity - watched.lastKnownSize) / watched.lastKnownSize * 100
                : 0
        )
    }
}
