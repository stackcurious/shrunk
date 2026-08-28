import SwiftUI
import StoreKit

struct SettingsView: View {
    @EnvironmentObject private var storeKit: StoreKitService
    @Environment(\.openURL) private var openURL
    @State private var showPaywall: Bool = false
    @State private var showDashboard: Bool = false
    @State private var showNotificationPrefs: Bool = false
    @State private var showStorePicker: Bool = false
    @State private var showClearHistoryConfirmation: Bool = false
    @State private var toastMessage: String?
    @State private var toastIsError: Bool = false
    @AppStorage(StorePickerViewModel.storeNameKey) private var storeName: String = ""

    var body: some View {
        NavigationStack {
            List {
                accountSection

                Section {
                    SettingsRow(icon: "cart.fill", iconTint: .shrunkRed,
                                label: storeName.isEmpty ? "Choose your store" : storeName) {
                        showStorePicker = true
                    }
                } header: {
                    Text("Store")
                } footer: {
                    Text("Live prices and store alternatives come from the Kroger store you pick. Prices from Kroger.")
                }

                Section {
                    SettingsRow(icon: "bell.badge", iconTint: .shrunkRed, label: "Notification preferences") {
                        showNotificationPrefs = true
                    }
                } header: {
                    Text("Alerts & notifications")
                } footer: {
                    Text("Tune what fires and when. iOS controls master delivery — we control everything else.")
                }

                Section {
                    SettingsRow(icon: "building.columns.fill", iconTint: .verdictGood, label: "USDA FoodData Central", isLink: true) {
                        if let url = URL(string: "https://fdc.nal.usda.gov") { openURL(url) }
                    }
                    SettingsRow(icon: "cart.fill", iconTint: .verdictGood, label: "Prices from Kroger", isLink: true) {
                        if let url = URL(string: "https://www.kroger.com") { openURL(url) }
                    }
                    SettingsRow(icon: "leaf.fill", iconTint: .verdictGood, label: "Open Food Facts (ODbL)", isLink: true) {
                        if let url = URL(string: "https://world.openfoodfacts.org") { openURL(url) }
                    }
                    // Destructive, irreversible, and it used to fire on the
                    // first tap with no confirmation and no feedback — and
                    // carried a `>` it doesn't earn (review S12).
                    SettingsRow(icon: "trash.fill", iconTint: .secondary,
                                label: "Clear scan history", showsDisclosure: false) {
                        showClearHistoryConfirmation = true
                    }
                } header: {
                    Text("Data sources")
                } footer: {
                    Text("Shrunk has no relationship with any brand or manufacturer. Size history comes from the USDA's public FoodData Central dataset, from shoppers' label photos, and from Kroger.")
                }

                Section("About") {
                    LabeledContent {
                        Text(versionString).monospacedDigit()
                    } label: {
                        Label("Version", systemImage: "info.circle.fill")
                    }
                    LabeledContent {
                        Text(String(DeviceIdentity.current.prefix(8))).monospacedDigit()
                    } label: {
                        Label("Device ID", systemImage: "number")
                    }
                    SettingsRow(icon: "hand.raised.fill", iconTint: .secondary, label: "Privacy policy", isLink: true) {
                        if let url = URL(string: "https://stackcurious.com/shrunk/privacy") { openURL(url) }
                    }
                    SettingsRow(icon: "doc.text.fill", iconTint: .secondary, label: "Terms of service", isLink: true) {
                        if let url = URL(string: "https://stackcurious.com/shrunk/terms") { openURL(url) }
                    }
                    SettingsRow(icon: "star.fill", iconTint: .verdictWarn, label: "Rate Shrunk") {
                        requestReview()
                    }
                    ShareLink(item: URL(string: "https://stackcurious.com/shrunk")!) {
                        Label("Share Shrunk", systemImage: "square.and.arrow.up")
                    }
                }

                Section {
                    positioningFooter
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .overlay(alignment: .bottom) { toastOverlay }
            .confirmationDialog(
                "Clear scan history?",
                isPresented: $showClearHistoryConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear scan history", role: .destructive) {
                    UserDefaults.standard.removeObject(forKey: "shrunk.recent_barcodes")
                    showToast("Scan history cleared")
                }
                Button("Keep it", role: .cancel) {}
            } message: {
                Text("The Recent row on the Scan tab empties. Your watchlist and alerts are untouched.")
            }
        }
        .sheet(isPresented: $showPaywall) {
            ProPaywallView()
        }
        .sheet(isPresented: $showDashboard) {
            SavingsDashboardView()
        }
        .sheet(isPresented: $showNotificationPrefs) {
            NotificationPreferencesView()
        }
        .sheet(isPresented: $showStorePicker) {
            StorePickerView()
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: storeKit.isProUser ? "checkmark.seal.fill" : "person.crop.circle")
                    .font(.title2)
                    .foregroundStyle(storeKit.isProUser ? Color.shrunkRed : Color.secondary)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(storeKit.isProUser ? "Shrunk Pro" : "Free plan")
                        .font(.headline)
                    Text(storeKit.isProUser
                         ? "Active — thanks for supporting independence."
                         : "Watching, alerts, full alternatives are Pro.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if storeKit.isProUser {
                    ProBadge(style: .pill)
                }
            }
            .padding(.vertical, 4)

            if storeKit.isProUser {
                SettingsRow(icon: "chart.line.uptrend.xyaxis", iconTint: .shrunkRed, label: "Savings") {
                    showDashboard = true
                }
                restoreButton
            } else {
                Button {
                    showPaywall = true
                } label: {
                    Label("Unlock Shrunk Pro · \(storeKit.yearlyProduct?.displayPrice ?? "$14.99")",
                          systemImage: "lock.open.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                restoreButton
            }
        }
    }

    /// Settings' restore fired and said nothing, unlike the paywall's — which
    /// already has the copy for every outcome (review S12).
    private var restoreButton: some View {
        Button("Restore purchases") {
            Task {
                await storeKit.restore()
                let failure = ProPaywallViewModel.restoreOutcomeMessage(
                    isPro: storeKit.isProUser,
                    error: storeKit.loadError
                )
                showToast(failure ?? "Shrunk Pro restored.", isError: failure != nil)
            }
        }
        .disabled(storeKit.purchaseInProgress)
    }

    // MARK: - Toast

    @ViewBuilder
    private var toastOverlay: some View {
        if let toastMessage {
            Toast(
                message: toastMessage,
                icon: toastIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                tint: toastIsError ? Color.shrunkRed : Color.verdictGood
            )
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: toastMessage) {
                try? await Task.sleep(nanoseconds: 2_800_000_000)
                withAnimation { self.toastMessage = nil }
            }
        }
    }

    private func showToast(_ message: String, isError: Bool = false) {
        toastIsError = isError
        withAnimation { toastMessage = message }
    }

    // MARK: - Positioning footer

    private var positioningFooter: some View {
        VStack(spacing: 4) {
            Text("They shrunk it. We caught them.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.shrunkRed)
            Text("Independent. No brand pays us. Ever.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private var versionString: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }

    private func requestReview() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        AppStore.requestReview(in: scene)
    }
}

// MARK: - Settings row

/// A tappable inset-grouped cell: tinted SF Symbol, title, and the disclosure
/// (chevron for in-app, `arrow.up.right` for an external link).
private struct SettingsRow: View {
    let icon: String
    let iconTint: Color
    let label: String
    let isLink: Bool
    let showsDisclosure: Bool
    let action: () -> Void

    init(
        icon: String,
        iconTint: Color,
        label: String,
        isLink: Bool = false,
        showsDisclosure: Bool = true,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.iconTint = iconTint
        self.label = label
        self.isLink = isLink
        self.showsDisclosure = showsDisclosure
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Label {
                    Text(label).foregroundStyle(Color(.label))
                } icon: {
                    Image(systemName: icon).foregroundStyle(iconTint)
                }
                Spacer(minLength: 8)
                if showsDisclosure {
                    Image(systemName: isLink ? "arrow.up.right" : "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
