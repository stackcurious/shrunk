import SwiftUI
import SwiftData
import UIKit

@main
struct ShrunkApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var storeKit = StoreKitService.shared
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("shrunk.has_completed_onboarding")
    private var hasCompletedOnboarding: Bool = false

    private let modelContainer: ModelContainer

    init() {
        // ModelContainer must be created synchronously so the background task
        // callback can re-create a context against the same store URL.
        do {
            modelContainer = try ModelContainer(for: WatchedProduct.self, ShrinkAlert.self)
        } catch {
            fatalError("SwiftData container failed to initialize: \(error)")
        }

        // The app delegate writes pushes into this container.
        PushInbox.shared.container = modelContainer

        NotificationScheduler.shared.registerBackgroundTask { [container = modelContainer] in
            await Self.runWatchlistSweep(container: container)
        }

        // Queue the first refresh so we have one pending if the user never
        // foregrounds again before tomorrow.
        NotificationScheduler.scheduleNextRefresh()
    }

    var body: some Scene {
        WindowGroup {
            RootView(hasCompletedOnboarding: $hasCompletedOnboarding)
                .environmentObject(storeKit)
                .tint(Color.shrunkRed)
                .task {
                    await storeKit.bootstrap()
                }
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            let container = modelContainer
            Task { @MainActor in
                await WatchlistService(context: ModelContext(container)).syncToBackend()
            }
        }
    }

    // MARK: - Background sweep

    @MainActor
    private static func runWatchlistSweep(container: ModelContainer) async {
        let context = ModelContext(container)
        let watchlist = WatchlistService(context: context)

        // Keep the Worker's copy of the watch list current, then do the
        // device-side live-size check that files `.unconfirmed` alerts (spec §7).
        await watchlist.syncToBackend()

        let prefsRaw = UserDefaults.standard.string(forKey: NotificationPreferences.appStorageKey)
            ?? NotificationPreferences.default.encoded()
        let prefs = NotificationPreferences.decoded(prefsRaw)

        for (watched, liveQuantity) in await watchlist.liveSizeCheck() {
            let percent = watched.lastKnownSize > 0
                ? (liveQuantity - watched.lastKnownSize) / watched.lastKnownSize
                : 0
            guard prefs.shouldFire(shrinkPercent: percent) else { continue }
            await NotificationScheduler.shared.scheduleLocalAlert(
                title: "\(watched.productName) may have changed size",
                body: "Your store lists a different size. Scan it to confirm.",
                barcode: watched.barcode
            )
        }
    }
}

// MARK: - Root

struct RootView: View {
    @Binding var hasCompletedOnboarding: Bool

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                MainTabsView()
            } else {
                OnboardingContainerView {
                    hasCompletedOnboarding = true
                }
            }
        }
        .sheet(item: Binding<ScannedBarcode?>(
            get: { PushInbox.shared.pendingBarcode.map { ScannedBarcode(id: $0) } },
            set: { PushInbox.shared.pendingBarcode = $0?.id }
        )) { wrapper in
            ResultView(barcode: wrapper.id)
        }
    }
}

// MARK: - Bottom tabs

struct MainTabsView: View {
    @AppStorage("shrunk.selected_tab") private var selectedTab: Int = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            ScannerView()
                .tabItem { Label("Scan", systemImage: "barcode.viewfinder") }
                .tag(0)
            BrowseView()
                .tabItem { Label("Browse", systemImage: "square.grid.2x2.fill") }
                .tag(1)
            WatchlistView()
                .tabItem { Label("Watchlist", systemImage: "bell.badge") }
                .tag(2)
            AlertsFeedView()
                .tabItem { Label("Alerts", systemImage: "bell") }
                .tag(3)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(4)
        }
    }
}
