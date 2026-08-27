import XCTest

/// Captures the six App Store screenshots listed in the "Screenshots" table of
/// `docs/APP_STORE_LISTING.md`. Each test attaches one PNG named after the file
/// the listing expects. To re-capture:
///
///     xcrun simctl status_bar <udid> override --time 9:41 --batteryState charged \
///         --batteryLevel 100 --cellularBars 4 --wifiBars 3
///     xcodegen generate
///     xcodebuild test -scheme Shrunk -only-testing:ShrunkUITests \
///         -destination 'platform=iOS Simulator,id=<udid>' \
///         -resultBundlePath shots.xcresult
///     xcrun xcresulttool export attachments --path shots.xcresult --output-path out
///
/// then rename `out/*.png` per `out/manifest.json`'s `suggestedHumanReadableName`
/// into `marketing/screenshots/v2/`. The simulator must be a 6.9" class device
/// (iPhone 16/17 Pro Max) so the frames come out at exactly 1320 x 2868.
///
/// The app runs against the **production** Worker
/// (`https://shrunk-api.stackcurious.workers.dev`), so every verdict, size
/// history and shelf price on screen is real data. `-ui-testing` only supplies
/// what a simulator physically cannot: the Pro entitlement (no StoreKit), the
/// camera feed, a seeded alert feed (no push), and the confirm sheet's entry
/// point. See `Shrunk/Support/UITestingOverrides.swift`.
final class ScreenshotTests: XCTestCase {

    // MARK: - Fixtures

    /// Kroger - Hyde Park, Cincinnati OH — from `/v1/kroger/locations?zip=45209`.
    private static let storeLocationId = "01400355"
    private static let storeDisplayName = "Kroger Hyde Park"

    /// The curated verified case behind the hero result screenshot: Maxwell
    /// House Original Roast, 30.6 oz → 24.5 oz, sourced in `data/trending.json`
    /// and served with both dated observations by `/v1/product`.
    private var featuredBarcode: String {
        ProcessInfo.processInfo.environment["SHRUNK_FEATURED_GTIN"] ?? "0043000071800"
    }

    /// A product Kroger actually prices at the store above, used for the
    /// live-price screenshot. Overridable from the environment so the capture
    /// script can re-point it when Kroger's assortment moves.
    private var pricedBarcode: String {
        ProcessInfo.processInfo.environment["SHRUNK_PRICED_GTIN"] ?? "0016000234932"
    }

    /// A barcode the backend has no product for, so the result screen offers the
    /// "Snap the label" contribute route.
    private var unknownBarcode: String {
        ProcessInfo.processInfo.environment["SHRUNK_UNKNOWN_GTIN"] ?? "0999999999992"
    }

    private let networkTimeout: TimeInterval = 40

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - Launch

    private func launchApp(pro: Bool = true, tab: Int = 0) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-ui-testing-tab", String(tab),
            "-ui-testing-store", Self.storeLocationId,
            "-ui-testing-store-name", Self.storeDisplayName,
            "-ui-testing-recent-a", featuredBarcode,
            "-ui-testing-recent-b", pricedBarcode,
            "-ui-testing-recent-c", unknownBarcode,
            // Light mode, and no "swipe up to open" tips over the capture.
            "-AppleInterfaceStyle", "Light",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"
        ]
        if !pro {
            app.launchArguments += ["-ui-testing-pro", "0"]
        }
        app.launch()
        return app
    }

    // MARK: - Capture

    private func capture(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        // Give SwiftUI a beat to settle animations (the reticle pulse, sheet
        // presentation) before the frame is grabbed.
        Thread.sleep(forTimeInterval: 2.0)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func require(_ element: XCUIElement,
                         _ what: String,
                         timeout: TimeInterval = 20,
                         file: StaticString = #filePath,
                         line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout),
                      "Timed out waiting for \(what)", file: file, line: line)
    }

    private func tab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let bar = app.tabBars.buttons[name]
        return bar.exists ? bar : app.buttons[name]
    }

    /// A slow, momentum-free drag, used to fine-tune a scroll position after
    /// `scroll(_:to:)` has run it to the end.
    private func nudgeDown(_ app: XCUIApplication, points: CGFloat) {
        let fraction = points / max(app.frame.height, 1)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3 + fraction))
        start.press(forDuration: 0.4,
                    thenDragTo: end,
                    withVelocity: .slow,
                    thenHoldForDuration: 0.4)
    }

    /// Scrolls the frontmost scroll view until `element` is on screen.
    private func scroll(_ app: XCUIApplication, to element: XCUIElement, maxSwipes: Int = 8) {
        var swipes = 0
        while !(element.exists && element.isHittable) && swipes < maxSwipes {
            app.swipeUp()
            swipes += 1
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    // MARK: - 01 · Result view for a curated verified case

    func test01ResultShrunk() {
        let app = launchApp()

        // The scan path, not Browse: `/v1/product` carries both dated curated
        // observations (the `/v1/feed` shortcut only dates the newer one), and
        // the sheet sits over the dark scanner rather than a half-lit Browse
        // grid.
        let recent = app.buttons[featuredBarcode]
        require(recent, "the recent-scan chip for \(featuredBarcode)")
        recent.tap()

        // The result view is loaded once the Then → Now comparison is up.
        require(app.staticTexts["THEN"], "the Then/Now comparison", timeout: networkTimeout)
        // Let the live-price panel finish its round trip to Kroger.
        Thread.sleep(forTimeInterval: 6)
        capture("01_result_shrunk")
    }

    // MARK: - 02 · Scanner

    func test02Scan() {
        let app = launchApp()
        require(app.staticTexts["SHRUNK"], "the scanner top bar")
        require(app.staticTexts["Searching for barcode"], "the scanner searching pill")
        capture("02_scan")
    }

    // MARK: - 03 · Live price panel

    func test03LivePrice() {
        let app = launchApp()

        // The scanner's RECENT row is the camera-free way into a result screen.
        let recent = app.buttons[pricedBarcode]
        require(recent, "the recent-scan chip for \(pricedBarcode)")
        recent.tap()

        let attribution = app.staticTexts["Prices from Kroger"]
        require(attribution, "the live-price panel", timeout: networkTimeout)
        Thread.sleep(forTimeInterval: 5)
        scroll(app, to: attribution)
        capture("03_live_price")
    }

    // MARK: - 04 · Contribute confirm sheet

    func test04Contribute() {
        let app = launchApp()

        let recent = app.buttons[unknownBarcode]
        require(recent, "the recent-scan chip for \(unknownBarcode)")
        recent.tap()

        let snap = app.buttons["Snap the label"]
        require(snap, "the contribute CTA on the not-found screen", timeout: networkTimeout)
        snap.tap()

        require(app.staticTexts["Check the size"], "the contribute confirm sheet")
        capture("04_contribute")
    }

    // MARK: - 05 · Alerts feed

    func test05Alerts() {
        let app = launchApp(tab: 3)
        tab(app, "Alerts").tap()
        require(app.staticTexts["Alerts"], "the Alerts header")
        capture("05_alerts")
    }

    // MARK: - 06 · Paywall

    func test06Paywall() {
        let app = launchApp(pro: false, tab: 4)
        tab(app, "Settings").tap()

        let unlock = app.buttons.containing(
            NSPredicate(format: "label BEGINSWITH %@", "Unlock Shrunk Pro")
        ).firstMatch
        require(unlock, "the Settings upgrade button")
        unlock.tap()

        require(app.staticTexts["Shrunk Pro"], "the paywall")
        // Apple wants the price, the renewal terms and both legal links in the
        // subscription screenshot, and the listing wants the preselected yearly
        // plan with its "Save 58%" badge. The paywall is taller than the screen,
        // so run it to the bottom and then ease back just far enough that the
        // Yearly row clears the top edge.
        let privacy = app.buttons["Privacy"]
        scroll(app, to: privacy)
        Thread.sleep(forTimeInterval: 0.6)
        nudgeDown(app, points: 130)
        capture("06_paywall")
    }
}
