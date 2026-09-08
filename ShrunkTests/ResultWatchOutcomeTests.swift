import XCTest
import SwiftData
@testable import Shrunk

/// `ResultViewModel.watchOutcome` is the pure decision behind the Result
/// screen's Watch button (spec §2).
///
/// Before it existed, `ResultView.addToWatchlist` and `WatchlistService.add`
/// both opened with `guard record.currentSize != nil else { return }`, so on
/// a product with no observation — the fresh on-miss case, e.g. Gatorade
/// `0052000338317` coming back with `observations: []` — tapping "Watch this
/// product" did nothing at all, with no toast, no haptic and no paywall
/// (spec §0). Every branch now names an outcome the view must act on.
@MainActor
final class ResultWatchOutcomeTests: XCTestCase {

    private let detector = ShrinkDetector()

    private func product(sizeHistory: [SizeRecord]) -> ShrunkProduct {
        ShrunkProduct(
            id: "0052000338317", name: "Gatorade Thirst Quencher", brand: "Gatorade",
            category: "Beverages", imageURL: nil, sizeHistory: sizeHistory,
            currentPrice: 1.89, currency: "USD"
        )
    }

    /// The common case — one observation, which is 98.5 % of the catalogue
    /// (spec §0). Watching it is legal: that observation is the baseline a
    /// future `size_drop` alert compares against (rule 3).
    private func singleObservationRecord() -> ShrinkRecord {
        detector.analyze(product: product(sizeHistory: [
            SizeRecord(date: Date(timeIntervalSince1970: 1_517_443_200),
                       quantity: 946.353, unit: "ml", source: "fdc")
        ]))
    }

    /// A fresh on-miss lookup: a name and nothing else.
    private func noSizeRecord() -> ShrinkRecord {
        detector.analyze(product: product(sizeHistory: []))
    }

    // MARK: - The four outcomes (spec §4)

    func test_singleObservationRecordWithPro_isWatch() {
        let outcome = ResultViewModel.watchOutcome(
            record: singleObservationRecord(), isPro: true, isAlreadyWatched: false
        )
        XCTAssertEqual(outcome, .watch, "one observation is enough to watch — it becomes the baseline")
    }

    func test_notPro_isPaywall() {
        let outcome = ResultViewModel.watchOutcome(
            record: singleObservationRecord(), isPro: false, isAlreadyWatched: false
        )
        XCTAssertEqual(outcome, .paywall)
    }

    func test_noCurrentSizeWithPro_isNeedsLabel() {
        let record = noSizeRecord()
        XCTAssertNil(record.currentSize, "precondition: nothing to watch yet")

        let outcome = ResultViewModel.watchOutcome(record: record, isPro: true, isAlreadyWatched: false)
        XCTAssertEqual(outcome, .needsLabel, "watching with zero observations is impossible (rule 3)")
    }

    func test_alreadyOnTheWatchlist_isAlreadyWatched() {
        let outcome = ResultViewModel.watchOutcome(
            record: singleObservationRecord(), isPro: true, isAlreadyWatched: true
        )
        XCTAssertEqual(outcome, .alreadyWatched,
                       "re-opening a watched product must start in the watched state, not forget it")
    }

    // MARK: - Precedence
    //
    // The two conditions that can hold at once are pinned here so the order is
    // a decision on the record rather than an accident of the `if` ladder.

    func test_noCurrentSizeAndNotPro_isNeedsLabelNotPaywall() {
        // Rule 1: "a scan never dead-ends". Paywalling an action that cannot
        // work at any price — there is no observation to use as a baseline —
        // would leave a free user on the Gatorade screen with nothing to do.
        // Label capture is not a Pro feature and is the step that unblocks
        // watching, so it wins over the paywall.
        let outcome = ResultViewModel.watchOutcome(
            record: noSizeRecord(), isPro: false, isAlreadyWatched: false
        )
        XCTAssertEqual(outcome, .needsLabel)
    }

    func test_alreadyWatchedWins_evenWhenProLapsed() {
        // An honest "On your watchlist" beats re-selling a product the user is
        // already watching.
        let outcome = ResultViewModel.watchOutcome(
            record: singleObservationRecord(), isPro: false, isAlreadyWatched: true
        )
        XCTAssertEqual(outcome, .alreadyWatched)
    }

    // MARK: - The bug this replaced
    //
    // A record with a current size and no *previous* size is precisely what
    // the old `guard record.currentSize != nil else { return }` pair let
    // through and what the "Not enough data yet" screen then refused to act
    // on. It must be a real, actionable `.watch`.

    func test_theSingleSnapshotCaseIsActionable() {
        let record = singleObservationRecord()
        XCTAssertNil(record.previousSize)
        XCTAssertNotNil(record.currentSize)
        XCTAssertEqual(record.verdict, .insufficientData)
        XCTAssertEqual(
            ResultViewModel.watchOutcome(record: record, isPro: true, isAlreadyWatched: false),
            .watch
        )
    }

    // MARK: - Watch intent across the paywall

    func test_pendingWatchWaitsUntilEntitlementIsActive() {
        XCTAssertEqual(
            ResultViewModel.resolvePendingWatch(
                isPending: true, isPro: false, isAlreadyWatched: false
            ),
            .wait
        )
    }

    func test_pendingWatchAddsAfterSuccessfulUpgrade() {
        XCTAssertEqual(
            ResultViewModel.resolvePendingWatch(
                isPending: true, isPro: true, isAlreadyWatched: false
            ),
            .add
        )
    }

    func test_noPendingWatchNeverAddsOnAnUnrelatedEntitlementChange() {
        XCTAssertEqual(
            ResultViewModel.resolvePendingWatch(
                isPending: false, isPro: true, isAlreadyWatched: false
            ),
            .clear
        )
    }

    func test_pendingWatchClearsIfProductWasAlreadyAddedElsewhere() {
        XCTAssertEqual(
            ResultViewModel.resolvePendingWatch(
                isPending: true, isPro: true, isAlreadyWatched: true
            ),
            .clear
        )
    }
}
