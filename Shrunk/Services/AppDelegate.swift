import UIKit
import UserNotifications

/// Owns APNs registration and delivery. Attached by `@UIApplicationDelegateAdaptor`
/// on `ShrunkApp`. `@MainActor` on the class means every callback can touch
/// `PushInbox` (also main-actor) directly, with no hops to get wrong.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Re-register every launch: iOS may rotate the token at any time, and
        // registering is a no-op until the user grants permission.
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = PushRegistration.hexString(from: deviceToken)
        UserDefaults.standard.set(hex, forKey: ShrunkAPIClient.apnsTokenKey)
        Task {
            await ShrunkAPIClient.shared.syncDevice(
                deviceId: DeviceIdentity.current,
                transactionJWS: "",
                apnsToken: hex
            )
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Simulators and unentitled builds land here. Everything else in the
        // app keeps working; we simply never receive a remote alert (spec §8).
    }

    /// Woken in the background by an alert push carrying `content-available`,
    /// so the row reaches the feed even if the banner is never tapped.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        PushInbox.shared.record(userInfo: userInfo) == nil ? .noData : .newData
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        PushInbox.shared.record(userInfo: notification.request.content.userInfo)
        return [.banner, .sound, .list]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        PushInbox.shared.record(userInfo: userInfo)
        PushInbox.shared.open(userInfo: userInfo)
    }
}

enum PushRegistration {
    /// APNs device token as lowercase hex — the form `/v1/devices` stores.
    static func hexString(from token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }
}
