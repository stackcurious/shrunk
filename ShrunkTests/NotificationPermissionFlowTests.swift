import XCTest
import UserNotifications
@testable import Shrunk

@MainActor
final class NotificationPermissionFlowTests: XCTestCase {
    func test_firstWatchRequestsPermission() {
        XCTAssertEqual(
            NotificationScheduler.watchFollowUp(for: .notDetermined),
            .requestPermission
        )
    }

    func test_existingPermissionOnlyRegistersForDelivery() {
        XCTAssertEqual(NotificationScheduler.watchFollowUp(for: .authorized), .register)
        XCTAssertEqual(NotificationScheduler.watchFollowUp(for: .provisional), .register)
        XCTAssertEqual(NotificationScheduler.watchFollowUp(for: .ephemeral), .register)
    }

    func test_deniedPermissionGuidesToSettingsWithoutPromptingAgain() {
        XCTAssertEqual(
            NotificationScheduler.watchFollowUp(for: .denied),
            .guideToSettings
        )
    }
}
