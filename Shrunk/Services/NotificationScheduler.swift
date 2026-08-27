import Foundation
import UIKit
import UserNotifications
import BackgroundTasks

@MainActor
final class NotificationScheduler {
    static let shared = NotificationScheduler()

    // Must match BGTaskSchedulerPermittedIdentifiers in Info.plist.
    nonisolated static let backgroundTaskID = "com.shrunk.refresh-watchlist"

    // MARK: - Permission

    @discardableResult
    func requestPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Asks for permission and, if granted, registers for APNs. The token
    /// arrives asynchronously in `AppDelegate`.
    @discardableResult
    func requestPermissionAndRegister() async -> Bool {
        let granted = await requestPermission()
        if granted { UIApplication.shared.registerForRemoteNotifications() }
        return granted
    }

    // MARK: - Local alerts

    /// A local notification for something the device worked out by itself —
    /// today that is only the `BGAppRefresh` live-size mismatch (spec §7).
    func scheduleLocalAlert(title: String, body: String, barcode: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["barcode": barcode]
        content.threadIdentifier = "shrunk-watchlist"

        let request = UNNotificationRequest(
            identifier: "local_\(barcode)_\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil  // immediate
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Background task

    /// Called once at app launch (`ShrunkApp.init`). Registers the handler that
    /// runs when iOS wakes us for a periodic watchlist sweep.
    func registerBackgroundTask(refreshHandler: @escaping () async -> Void) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundTaskID,
            using: nil
        ) { task in
            // Schedule the next sweep up-front so we always have one queued.
            Self.scheduleNextRefresh()

            let work = Task { @MainActor in
                await refreshHandler()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = {
                work.cancel()
                task.setTaskCompleted(success: false)
            }
        }
    }

    /// Submit a background-app-refresh request for ~24h from now. iOS may
    /// run it later or sooner depending on system conditions and user habits.
    nonisolated static func scheduleNextRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60 * 24)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Clears delivered notifications and pending requests — called from Settings.
    func clearAllPending() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
}
