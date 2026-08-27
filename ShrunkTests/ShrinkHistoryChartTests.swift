import XCTest
@testable import Shrunk

final class ShrinkHistoryChartTests: XCTestCase {

    private func record(_ daysAgo: Double, _ quantity: Double) -> SizeRecord {
        SizeRecord(
            date: Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * 86_400),
            quantity: quantity,
            unit: "g",
            source: "fdc"
        )
    }

    private var fourPoints: [SizeRecord] {
        // Deliberately out of order — the chart sorts.
        [record(300, 28), record(1500, 32), record(0, 26), record(900, 30)]
    }

    func test_proSeesEveryObservationOldestFirst() {
        let visible = ShrinkHistoryChart.visibleHistory(fourPoints, isPro: true)
        XCTAssertEqual(visible.map(\.quantity), [32, 30, 28, 26])
    }

    func test_freeSeesOnlyTheLatestTwo() {
        let visible = ShrinkHistoryChart.visibleHistory(fourPoints, isPro: false)
        XCTAssertEqual(visible.map(\.quantity), [28, 26])
    }

    func test_freeWithExactlyTwoObservationsSeesBoth() {
        let two = [record(300, 28), record(0, 26)]
        XCTAssertEqual(ShrinkHistoryChart.visibleHistory(two, isPro: false).map(\.quantity), [28, 26])
    }

    func test_freeWithOneObservationSeesIt() {
        XCTAssertEqual(ShrinkHistoryChart.visibleHistory([record(0, 26)], isPro: false).map(\.quantity), [26])
    }

    func test_emptyHistoryStaysEmptyForBothTiers() {
        XCTAssertTrue(ShrinkHistoryChart.visibleHistory([], isPro: true).isEmpty)
        XCTAssertTrue(ShrinkHistoryChart.visibleHistory([], isPro: false).isEmpty)
    }

    func test_hiddenCountDrivesTheUpgradeAffordance() {
        XCTAssertEqual(ShrinkHistoryChart.hiddenCount(fourPoints, isPro: false), 2)
        XCTAssertEqual(ShrinkHistoryChart.hiddenCount(fourPoints, isPro: true), 0)
        XCTAssertEqual(ShrinkHistoryChart.hiddenCount([record(0, 26), record(1, 28)], isPro: false), 0)
    }
}
