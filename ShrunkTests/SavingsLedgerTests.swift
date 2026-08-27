import XCTest
@testable import Shrunk

final class SavingsLedgerTests: XCTestCase {

    private func alert(
        barcode: String = "0028400642255",
        name: String = "Doritos Nacho Cheese",
        percent: Double = -12.5,
        price: Double? = 4.99,
        daysAgo: Double = 1,
        kind: ShrinkAlert.Kind = .newShrink
    ) -> ShrinkAlert {
        ShrinkAlert(
            barcode: barcode,
            productName: name,
            brand: "Doritos",
            kind: kind,
            shrinkPercent: percent,
            currentPrice: price,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * 86_400)
        )
    }

    private func watched(
        barcode: String = "0052000012897",
        name: String = "Gatorade Cool Blue",
        percent: Double = -10,
        price: Double? = 2.00
    ) -> WatchedProduct {
        WatchedProduct(
            barcode: barcode,
            productName: name,
            brand: "Gatorade",
            lastKnownSize: 828,
            lastKnownUnit: "ml",
            lastKnownPrice: price,
            lastShrinkPercent: percent
        )
    }

    // MARK: - Frequency

    func test_purchasesPerYear() {
        XCTAssertEqual(SavingsLedger.purchasesPerYear(for: .weekly), 52)
        XCTAssertEqual(SavingsLedger.purchasesPerYear(for: .biweekly), 26)
        XCTAssertEqual(SavingsLedger.purchasesPerYear(for: .monthly), 12)
    }

    // MARK: - Math

    func test_annualIsShrinkFractionTimesPriceTimesPurchases() {
        let ledger = SavingsLedger.build(alerts: [alert()], watchlist: [], shopFrequency: .biweekly)
        // 0.125 × $4.99 × 26 = $16.2175
        XCTAssertEqual(ledger.entries.count, 1)
        XCTAssertEqual(ledger.entries[0].shrinkPercentAbs, 0.125, accuracy: 0.0001)
        XCTAssertEqual(ledger.entries[0].annual, 16.2175, accuracy: 0.001)
        XCTAssertEqual(ledger.totalAnnual, 16.2175, accuracy: 0.001)
    }

    func test_frequencyScalesTheTotal() {
        let weekly = SavingsLedger.build(alerts: [alert()], watchlist: [], shopFrequency: .weekly)
        let monthly = SavingsLedger.build(alerts: [alert()], watchlist: [], shopFrequency: .monthly)
        XCTAssertEqual(weekly.totalAnnual / monthly.totalAnnual, 52.0 / 12.0, accuracy: 0.0001)
    }

    func test_watchedProductsCountToo() {
        let ledger = SavingsLedger.build(alerts: [], watchlist: [watched()], shopFrequency: .monthly)
        // 0.10 × $2.00 × 12 = $2.40
        XCTAssertEqual(ledger.entries.count, 1)
        XCTAssertEqual(ledger.entries[0].annual, 2.40, accuracy: 0.001)
    }

    func test_alertsAndWatchlistSumTogether() {
        let ledger = SavingsLedger.build(alerts: [alert()], watchlist: [watched()], shopFrequency: .monthly)
        XCTAssertEqual(ledger.entries.count, 2)
        XCTAssertEqual(ledger.totalAnnual, 7.485 + 2.40, accuracy: 0.001)
    }

    // MARK: - Filtering

    func test_productsWithoutAPriceAreExcluded() {
        let ledger = SavingsLedger.build(
            alerts: [alert(price: nil), alert(barcode: "0000000000102", price: 0)],
            watchlist: [watched(price: 0)],
            shopFrequency: .weekly
        )
        XCTAssertTrue(ledger.entries.isEmpty)
        XCTAssertEqual(ledger.totalAnnual, 0)
    }

    func test_productsWithoutAShrinkVerdictAreExcluded() {
        let unchanged = alert(percent: -0.4)   // inside the ±1% unchanged band
        let grew = alert(barcode: "0000000000017", percent: 3.0)
        let ledger = SavingsLedger.build(alerts: [unchanged, grew], watchlist: [], shopFrequency: .weekly)
        XCTAssertTrue(ledger.entries.isEmpty)
    }

    func test_minorShrinkStillCounts() {
        let ledger = SavingsLedger.build(alerts: [alert(percent: -2.0)], watchlist: [], shopFrequency: .weekly)
        XCTAssertEqual(ledger.entries.count, 1)
    }

    func test_everyConfirmedShrinkKindCounts_butDigestAndUnconfirmedDoNot() {
        let sizeDropAlert = alert(barcode: "0000000000034", kind: .sizeDrop)
        let verifiedCaseAlert = alert(barcode: "0000000000041", kind: .verifiedCase)
        let digestAlert = alert(barcode: "0000000000058", kind: .digest)
        let unconfirmedAlert = alert(barcode: "0000000000065", kind: .unconfirmed)
        let priceHikeAlert = alert(barcode: "0000000000072", kind: .priceHike)
        let stableAlert = alert(barcode: "0000000000089", kind: .stable)

        let ledger = SavingsLedger.build(
            alerts: [sizeDropAlert, verifiedCaseAlert, digestAlert, unconfirmedAlert, priceHikeAlert, stableAlert],
            watchlist: [],
            shopFrequency: .weekly
        )
        XCTAssertEqual(Set(ledger.entries.map(\.id)), Set(["0000000000034", "0000000000041"]))
    }

    // MARK: - Shape

    func test_oneEntryPerBarcodeWithTheAlertWinning() {
        let sameBarcode = watched(barcode: "0028400642255", name: "Doritos (stale copy)", percent: -3, price: 9.99)
        let ledger = SavingsLedger.build(alerts: [alert()], watchlist: [sameBarcode], shopFrequency: .biweekly)
        XCTAssertEqual(ledger.entries.count, 1)
        XCTAssertEqual(ledger.entries[0].productName, "Doritos Nacho Cheese")
        XCTAssertEqual(ledger.entries[0].currentPrice, 4.99)
    }

    func test_theNewestAlertWinsOverAnOlderAlertForTheSameBarcode() {
        // Passed newest-first, matching the @Query(sort: .reverse) callers use.
        let newer = alert(percent: -20, price: 5.00, daysAgo: 1)
        let older = alert(percent: -20, price: 3.00, daysAgo: 10)
        let ledger = SavingsLedger.build(alerts: [newer, older], watchlist: [], shopFrequency: .weekly)
        XCTAssertEqual(ledger.entries.count, 1)
        XCTAssertEqual(ledger.entries[0].currentPrice, 5.00)
    }

    func test_entriesAreSortedByAnnualDescending() {
        let big = alert(barcode: "0000000000010", name: "Big", percent: -20, price: 10)
        let small = alert(barcode: "0000000000027", name: "Small", percent: -2, price: 1)
        let ledger = SavingsLedger.build(alerts: [small, big], watchlist: [], shopFrequency: .weekly)
        XCTAssertEqual(ledger.entries.map(\.productName), ["Big", "Small"])
    }

    func test_emptyInputsGiveTheEmptyLedger() {
        XCTAssertEqual(SavingsLedger.build(alerts: [], watchlist: [], shopFrequency: .weekly), .empty)
    }

    func test_totalDisplayIsWholeDollars() {
        let ledger = SavingsLedger.build(alerts: [alert()], watchlist: [], shopFrequency: .biweekly)
        XCTAssertEqual(ledger.totalDisplay, "$16")
    }
}
