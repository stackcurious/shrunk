import SwiftUI
import SwiftData

@main
struct ShrunkApp: App {
    @StateObject private var storeKit = StoreKitService.shared

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
    }

    // MARK: - Background sweep

    @MainActor
    private static func runWatchlistSweep(container: ModelContainer) async {
        let context = ModelContext(container)
        let watchlist = WatchlistService(context: context)
        let detected = await watchlist.refreshAll()

        let prefsRaw = UserDefaults.standard.string(forKey: NotificationPreferences.appStorageKey)
            ?? NotificationPreferences.default.encoded()
        let prefs = NotificationPreferences.decoded(prefsRaw)

        for (watched, record) in detected where watched.alertEnabled {
            // Always log the alert to SwiftData so the user sees it in the feed
            // and the Savings Dashboard counts it. The iOS push is filtered.
            let alert = ShrinkAlert.newShrink(from: watched, record: record)
            context.insert(alert)
            try? context.save()

            if prefs.shouldFire(shrinkPercent: record.shrinkPercent) {
                await NotificationScheduler.shared.scheduleShrinkAlert(
                    productName: watched.productName,
                    brand: watched.brand,
                    record: record,
                    barcode: watched.barcode
                )
            }
        }
    }
}

// MARK: - Root

struct RootView: View {
    @Binding var hasCompletedOnboarding: Bool

    var body: some View {
        if hasCompletedOnboarding {
            MainTabsView()
        } else {
            OnboardingContainerView {
                hasCompletedOnboarding = true
            }
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
