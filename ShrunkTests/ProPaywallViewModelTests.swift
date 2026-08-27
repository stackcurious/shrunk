import XCTest
@testable import Shrunk

@MainActor
final class ProPaywallViewModelTests: XCTestCase {

    private func loaded(isTrialEligible: Bool? = true) -> ProPaywallViewModel {
        let vm = ProPaywallViewModel()
        vm.apply(
            monthlyDisplayPrice: "$2.99", monthlyPrice: Decimal(string: "2.99"),
            yearlyDisplayPrice: "$14.99", yearlyPrice: Decimal(string: "14.99"),
            isTrialEligible: isTrialEligible
        )
        return vm
    }

    // MARK: - Savings

    func test_savingsPercent_matchesTheSpecsFiftyEight() {
        XCTAssertEqual(
            ProPaywallViewModel.savingsPercent(
                monthlyPrice: Decimal(string: "2.99")!,
                yearlyPrice: Decimal(string: "14.99")!
            ),
            58
        )
    }

    func test_savingsPercent_isNilWhenYearlyIsNotCheaper() {
        XCTAssertNil(
            ProPaywallViewModel.savingsPercent(monthlyPrice: 1, yearlyPrice: 24)
        )
    }

    func test_savingsBadge_readsSave58() {
        XCTAssertEqual(loaded().savingsBadge, "Save 58%")
    }

    // MARK: - Selection

    func test_yearlyIsPreselected() {
        XCTAssertEqual(ProPaywallViewModel().selectedPlan, .yearly)
        XCTAssertEqual(loaded().selectedPlan, .yearly)
    }

    func test_defaultPricesBeforeStoreKitLoads() {
        let vm = ProPaywallViewModel()
        XCTAssertEqual(vm.monthlyDisplayPrice, "$2.99")
        XCTAssertEqual(vm.yearlyDisplayPrice, "$14.99")
    }

    func test_applyKeepsDefaultsWhenStoreKitReturnsNothing() {
        let vm = ProPaywallViewModel()
        vm.apply(monthlyDisplayPrice: nil, monthlyPrice: nil,
                 yearlyDisplayPrice: nil, yearlyPrice: nil, isTrialEligible: true)
        XCTAssertEqual(vm.monthlyDisplayPrice, "$2.99")
        XCTAssertEqual(vm.yearlyDisplayPrice, "$14.99")
        XCTAssertEqual(vm.savingsBadge, "Save 58%")
    }

    func test_applyUsesStoreKitPricesForOtherStorefronts() {
        let vm = ProPaywallViewModel()
        vm.apply(monthlyDisplayPrice: "€3.49", monthlyPrice: Decimal(string: "3.49"),
                 yearlyDisplayPrice: "€19.99", yearlyPrice: Decimal(string: "19.99"),
                 isTrialEligible: true)
        XCTAssertEqual(vm.monthlyDisplayPrice, "€3.49")
        XCTAssertEqual(vm.yearlyDisplayPrice, "€19.99")
        XCTAssertEqual(vm.savingsBadge, "Save 52%")
    }

    // MARK: - CTA and fineprint

    func test_trialCTA_onlyAppliesToYearly() {
        let vm = loaded()
        XCTAssertTrue(vm.trialAppliesToSelection)
        XCTAssertEqual(vm.ctaTitle, "Start 7-day free trial")

        vm.selectedPlan = .monthly
        XCTAssertFalse(vm.trialAppliesToSelection)
        XCTAssertEqual(vm.ctaTitle, "Subscribe for $2.99/month")
    }

    func test_ineligibleUserSeesAPlainYearlyCTA() {
        let vm = loaded(isTrialEligible: false)
        XCTAssertFalse(vm.trialAppliesToSelection)
        XCTAssertEqual(vm.ctaTitle, "Subscribe for $14.99/year")
    }

    // MARK: - I7: tri-state eligibility — unresolved must never advertise a trial

    func test_unresolvedTrialEligibility_neverAppliesEvenOnYearly() {
        let vm = loaded(isTrialEligible: nil)
        XCTAssertEqual(vm.selectedPlan, .yearly)
        XCTAssertFalse(vm.trialAppliesToSelection, "unknown must read as no-trial, not as eligible")
        XCTAssertEqual(vm.ctaTitle, "Subscribe for $14.99/year")
        XCTAssertEqual(vm.fineprint, "$14.99/year. Cancel anytime in Settings.")
    }

    func test_defaultViewModel_isUnresolvedBeforeApplyRuns() {
        // Before `apply` ever runs (the paywall's first frame, or a failed
        // load), the CTA must fall back to "Subscribe" rather than
        // optimistically offering a trial (I7 — this replaces the old
        // `Bool = true` default).
        let vm = ProPaywallViewModel()
        XCTAssertNil(vm.isTrialEligible)
        XCTAssertFalse(vm.trialAppliesToSelection)
        XCTAssertEqual(vm.ctaTitle, "Subscribe for $14.99/year")
    }

    func test_fineprintNamesThePriceAfterTheTrial() {
        let vm = loaded()
        XCTAssertEqual(vm.fineprint, "7 days free, then $14.99/year. Cancel anytime in Settings.")

        vm.selectedPlan = .monthly
        XCTAssertEqual(vm.fineprint, "$2.99/month. Cancel anytime in Settings.")
    }

    // MARK: - Auto-renewal disclosure (App Review 3.1.2)

    func test_autoRenewalDisclosure_statesTheRequiredTerms() {
        let disclosure = ProPaywallViewModel.autoRenewalDisclosure
        XCTAssertTrue(disclosure.contains("charged to your Apple Account at confirmation of purchase"))
        XCTAssertTrue(disclosure.contains("renews automatically unless auto-renew is turned off at least 24 hours"))
        XCTAssertTrue(disclosure.contains("charged for renewal within 24 hours before the current period ends"))
        XCTAssertTrue(disclosure.contains("unused portion of a free trial is forfeited"))
    }

    func test_autoRenewalDisclosure_matchesTheAppStoreListingDocVerbatim() {
        // Must stay byte-identical to docs/APP_STORE_LISTING.md:97 (through
        // the trial-forfeiture sentence) so the app and the listing can't
        // drift — this is the text App Review 3.1.2 requires on the paywall.
        XCTAssertEqual(
            ProPaywallViewModel.autoRenewalDisclosure,
            "Payment is charged to your Apple Account at confirmation of purchase. The subscription renews automatically unless auto-renew is turned off at least 24 hours before the end of the current period. Your account is charged for renewal within 24 hours before the current period ends. Any unused portion of a free trial is forfeited when you purchase a subscription."
        )
    }

    // MARK: - Restore outcome

    func test_restoreOutcomeMessage_isNilWhenRestoreFoundAnActiveSubscription() {
        XCTAssertNil(ProPaywallViewModel.restoreOutcomeMessage(isPro: true, error: nil))
        XCTAssertNil(ProPaywallViewModel.restoreOutcomeMessage(isPro: true, error: "some transient error"))
    }

    func test_restoreOutcomeMessage_saysNoPurchasesWhenNotProAndNoError() {
        XCTAssertEqual(
            ProPaywallViewModel.restoreOutcomeMessage(isPro: false, error: nil),
            "No purchases to restore."
        )
    }

    func test_restoreOutcomeMessage_includesTheErrorWhenOneIsPresent() {
        XCTAssertEqual(
            ProPaywallViewModel.restoreOutcomeMessage(isPro: false, error: "The network connection was lost."),
            "No purchases to restore. The network connection was lost."
        )
    }
}
