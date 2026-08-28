import XCTest
@testable import Shrunk

/// The share card's whole payload is a Then→Now claim: "They took N ml /
/// from X → Y". `ResultView` gated the Share button on `previousSize != nil`
/// alone, which since the S13 fix also matches the two `.insufficientData`
/// states the Result screen itself refuses to draw a comparison for — the
/// zero-quantity guard and the cross-source plausibility clamp both return
/// `.insufficientData` *with* a `previousSize`. So the screen said "No shrink
/// on record" while the shareable PNG said "from 0ml → 946.4ml".
///
/// One predicate now answers "is this a comparison we stand behind", and both
/// the button and the renderer ask it.
final class ShareCardGateTests: XCTestCase {

    // MARK: - Fixtures

    private func size(_ quantity: Double, _ unit: String = "ml", daysAgo: Int = 0) -> SizeRecord {
        SizeRecord(date: Date(timeIntervalSince1970: 1_700_000_000 - Double(daysAgo) * 86_400),
                   quantity: quantity, unit: unit, source: "test")
    }

    private var product: ShrunkProduct {
        ShrunkProduct(id: "0052000135138", name: "Thirst Quencher", brand: "Gatorade",
                      category: "beverages", imageURL: nil, sizeHistory: [],
                      currentPrice: nil, currency: "USD")
    }

    private func record(verdict: ShrinkRecord.ShrinkVerdict,
                        previous: SizeRecord?,
                        current: SizeRecord?,
                        percent: Double = 0) -> ShrinkRecord {
        ShrinkRecord(product: product, previousSize: previous, currentSize: current,
                     shrinkPercent: percent, priceThen: nil, priceNow: nil,
                     costPerUnitThen: nil, costPerUnitNow: nil,
                     priceIsFromStoreSnapshot: false, verdict: verdict)
    }

    // MARK: - Shareable

    func test_shrinkWithBothSizesIsShareable() {
        for verdict in [ShrinkRecord.ShrinkVerdict.significantShrink, .moderateShrink, .minorShrink] {
            let r = record(verdict: verdict,
                           previous: size(946.4, daysAgo: 365),
                           current: size(828.1),
                           percent: -12.5)
            XCTAssertTrue(ShareCardRenderer.canShare(record: r), "\(verdict) is a real Then→Now")
        }
    }

    func test_grewIsShareable() {
        let r = record(verdict: .grew,
                       previous: size(100, "g", daysAgo: 365),
                       current: size(110, "g"),
                       percent: 10)
        XCTAssertTrue(ShareCardRenderer.canShare(record: r))
    }

    // MARK: - Not shareable

    /// `ShrinkDetector`'s cross-source plausibility clamp: two real sizes, but
    /// the pair was rejected, so the verdict is `.insufficientData`. The
    /// Result screen draws the single "Current size" card here — the card must
    /// not draw a comparison the screen just refused to.
    func test_clampedPairIsNotShareable() {
        let r = record(verdict: .insufficientData,
                       previous: size(1360, "g", daysAgo: 400),
                       current: size(340, "g"))
        XCTAssertFalse(ShareCardRenderer.canShare(record: r))
    }

    /// The zero-quantity guard: `previousSize` is present but meaningless.
    /// This is the "from 0ml → 946.4ml" card in the review.
    func test_zeroQuantityPreviousIsNotShareable() {
        let r = record(verdict: .insufficientData,
                       previous: size(0, daysAgo: 400),
                       current: size(946.4))
        XCTAssertFalse(ShareCardRenderer.canShare(record: r))
    }

    func test_singleSnapshotIsNotShareable() {
        let r = record(verdict: .insufficientData, previous: nil, current: size(762.6, "g"))
        XCTAssertFalse(ShareCardRenderer.canShare(record: r))
    }

    func test_noSizesAtAllIsNotShareable() {
        XCTAssertFalse(ShareCardRenderer.canShare(record: record(verdict: .insufficientData,
                                                                 previous: nil, current: nil)))
        XCTAssertFalse(ShareCardRenderer.canShare(record: record(verdict: .significantShrink,
                                                                 previous: size(32, "oz"), current: nil)),
                       "a verdict without a current size still has nothing to draw")
    }

    /// The gate agrees with `ResultView.comparisonRow`, which is the point:
    /// both are "verdict we stand behind, and two sizes to draw". `.unchanged`
    /// is unreachable from `ShrinkDetector.analyze` today (adjacent size runs
    /// differ by more than the ±1% tolerance by construction), but spec §2
    /// lists Share on the unchanged/grew row, so the predicate keeps it rather
    /// than hard-coding `isShrink || .grew`.
    func test_unchangedStaysShareablePerSpecSection2() {
        let r = record(verdict: .unchanged,
                       previous: size(946.4, daysAgo: 365),
                       current: size(946.4))
        XCTAssertTrue(ShareCardRenderer.canShare(record: r))
    }
}
