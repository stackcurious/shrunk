import XCTest
@testable import Shrunk

@MainActor
final class OnboardingViewModelTests: XCTestCase {

    func test_flowIsExactlyFourSteps() {
        XCTAssertEqual(OnboardingViewModel.Step.allCases.count, 4)
        XCTAssertEqual(
            OnboardingViewModel.Step.allCases,
            [.welcome, .categories, .store, .paywall]
        )
    }

    func test_startsOnWelcomeAndWalksToThePaywall() {
        let vm = OnboardingViewModel()
        XCTAssertEqual(vm.step, .welcome)
        vm.advance()
        XCTAssertEqual(vm.step, .categories)
        vm.toggleCategory(.snacks)
        vm.advance()
        XCTAssertEqual(vm.step, .store)
        vm.advance()
        XCTAssertEqual(vm.step, .paywall)
        vm.advance()
        XCTAssertEqual(vm.step, .paywall, "the paywall is the last step")
    }

    func test_backWalksTheOtherWayAndStopsAtWelcome() {
        let vm = OnboardingViewModel()
        vm.advance()
        vm.back()
        XCTAssertEqual(vm.step, .welcome)
        vm.back()
        XCTAssertEqual(vm.step, .welcome)
    }

    func test_categoriesStepRequiresAtLeastOneCategory() {
        let vm = OnboardingViewModel()
        vm.advance()
        XCTAssertFalse(vm.canAdvance)
        vm.toggleCategory(.dairy)
        XCTAssertTrue(vm.canAdvance)
        vm.toggleCategory(.dairy)
        XCTAssertFalse(vm.canAdvance)
    }

    func test_storeStepIsSkippable() {
        let vm = OnboardingViewModel()
        vm.advance()
        vm.toggleCategory(.drinks)
        vm.advance()
        XCTAssertEqual(vm.step, .store)
        XCTAssertTrue(vm.canAdvance, "the store step never blocks")
        vm.skipStore()
        XCTAssertEqual(vm.step, .paywall)
    }

    func test_shopFrequencyDefaultsToBiweeklyAndIsSettable() {
        let vm = OnboardingViewModel()
        XCTAssertEqual(vm.profile.shopFrequency, .biweekly)
        vm.selectFrequency(.weekly)
        XCTAssertEqual(vm.profile.shopFrequency, .weekly)
    }

    func test_progressFractionRunsZeroToOne() {
        let vm = OnboardingViewModel()
        XCTAssertEqual(vm.progressFraction, 0, accuracy: 0.001)
        vm.step = .paywall
        XCTAssertEqual(vm.progressFraction, 1, accuracy: 0.001)
    }
}

final class OnboardingProfileTests: XCTestCase {

    func test_emptyProfileDefaultsToBiweeklyAndNoCategories() {
        XCTAssertEqual(OnboardingProfile.empty.shopFrequency, .biweekly)
        XCTAssertTrue(OnboardingProfile.empty.categories.isEmpty)
    }

    func test_roundTripsThroughJSON() {
        var profile = OnboardingProfile.empty
        profile.categories = [.snacks, .paper]
        profile.shopFrequency = .monthly

        let decoded = OnboardingProfile.decoded(profile.encoded())
        XCTAssertEqual(decoded.categories, [.snacks, .paper])
        XCTAssertEqual(decoded.shopFrequency, .monthly)
    }

    func test_decodesAnOldProfileThatStillCarriesRemovedFields() {
        // Installs from before this phase have household/spend keys in
        // UserDefaults; they must decode, not reset the user to zero.
        let legacy = #"{"householdSize":"threeFour","shopFrequency":"weekly","categories":["dairy"],"monthlySpend":650}"#
        let decoded = OnboardingProfile.decoded(legacy)
        XCTAssertEqual(decoded.categories, [.dairy])
        XCTAssertEqual(decoded.shopFrequency, .weekly)
    }

    func test_decodesAProfileWithNoFrequencyAtAll() {
        let decoded = OnboardingProfile.decoded("{}")
        XCTAssertEqual(decoded.shopFrequency, .biweekly)
        XCTAssertTrue(decoded.categories.isEmpty)
    }
}
