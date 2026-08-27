import XCTest
@testable import Shrunk

@MainActor
final class ProPaywallViewModelTests: XCTestCase {

    private func loaded(isTrialEligible: Bool = true) -> ProPaywallViewModel {
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

    func test_fineprintNamesThePriceAfterTheTrial() {
        let vm = loaded()
        XCTAssertEqual(vm.fineprint, "7 days free, then $14.99/year. Cancel anytime in Settings.")

        vm.selectedPlan = .monthly
        XCTAssertEqual(vm.fineprint, "$2.99/month. Cancel anytime in Settings.")
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
