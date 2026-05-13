import SwiftUI
import StoreKit

struct SettingsView: View {
    @EnvironmentObject private var storeKit: StoreKitService
    @Environment(\.openURL) private var openURL
    @State private var showPaywall: Bool = false
    @State private var showDashboard: Bool = false
    @State private var showNotificationPrefs: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: ShrunkTheme.Spacing.lg) {
                ShrunkPageHeader(title: "Settings")
                    .padding(.horizontal, -ShrunkTheme.Spacing.lg)  // cancel outer padding
                accountCard
                    sectionGroup(title: "Alerts & notifications", subtitle: "Tune what fires and when. iOS controls master delivery — we control everything else.") {
                        SettingsRow(icon: "bell.badge", iconTint: .shrunkRed, label: "Notification preferences") {
                            showNotificationPrefs = true
                        }
                    }
                    sectionGroup(title: "Data", subtitle: "Shrunk has no relationship with any brand or manufacturer. Open Food Facts is a nonprofit, community-maintained database.") {
                        SettingsRow(icon: "leaf.fill", iconTint: .verdictGood, label: "Open Food Facts", isLink: true) {
                            if let url = URL(string: "https://world.openfoodfacts.org") { openURL(url) }
                        }
                        SettingsRow(icon: "plus.circle.fill", iconTint: .verdictGood, label: "Contribute a product", isLink: true) {
                            if let url = URL(string: "https://world.openfoodfacts.org/contribute") { openURL(url) }
                        }
                        SettingsRow(icon: "trash.fill", iconTint: .smoke, label: "Clear scan history") {
                            UserDefaults.standard.removeObject(forKey: "shrunk.recent_barcodes")
                        }
                    }
                    sectionGroup(title: "About", subtitle: nil) {
                        SettingsValueRow(icon: "info.circle.fill", iconTint: .smoke, label: "Version", value: versionString)
                        SettingsRow(icon: "hand.raised.fill", iconTint: .smoke, label: "Privacy policy", isLink: true) {
                            if let url = URL(string: "https://shrunk.app/privacy") { openURL(url) }
                        }
                        SettingsRow(icon: "doc.text.fill", iconTint: .smoke, label: "Terms of service", isLink: true) {
                            if let url = URL(string: "https://shrunk.app/terms") { openURL(url) }
                        }
                        SettingsRow(icon: "star.fill", iconTint: .verdictWarn, label: "Rate Shrunk") {
                            requestReview()
                        }
                        SettingsShareRow()
                    }
                    positioningFooter
                }
            .padding(.horizontal, ShrunkTheme.Spacing.lg)
            .padding(.bottom, 100)
        }
        .scrollIndicators(.hidden)
        .background(Color.paper.ignoresSafeArea())
        .sheet(isPresented: $showPaywall) {
            ProPaywallView()
        }
        .sheet(isPresented: $showDashboard) {
            SavingsDashboardView()
        }
        .sheet(isPresented: $showNotificationPrefs) {
            NotificationPreferencesView()
        }
    }

    // MARK: - Account hero

    private var accountCard: some View {
        VStack(spacing: ShrunkTheme.Spacing.md) {
            HStack(spacing: ShrunkTheme.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(storeKit.isProUser ? AnyShapeStyle(LinearGradient.shrunkRedDiagonal) : AnyShapeStyle(Color.mist))
                        .frame(width: 56, height: 56)
                    Image(systemName: storeKit.isProUser ? "checkmark.seal.fill" : "person.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(storeKit.isProUser ? .white : Color.smoke)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(storeKit.isProUser ? "Shrunk Pro" : "Free plan")
                        .font(.shrunkHeadline)
                        .foregroundStyle(Color.ink)
                    Text(storeKit.isProUser ? "Active — thanks for supporting independence." : "Watching, alerts, full alternatives are Pro.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.smoke)
                        .lineLimit(2)
                }
                Spacer()
                if storeKit.isProUser {
                    ProBadge(style: .pill)
                }
            }
            if storeKit.isProUser {
                HStack(spacing: 8) {
                    smallButton("Savings", icon: "chart.line.uptrend.xyaxis") {
                        showDashboard = true
                    }
                    smallButton("Restore", icon: "arrow.clockwise") {
                        Task { await storeKit.restore() }
                    }
                }
            } else {
                ShrunkButton("Unlock Shrunk Pro · \(storeKit.product?.displayPrice ?? "$9.99")", icon: "lock.open.fill") {
                    showPaywall = true
                }
                Button("Restore purchases") {
                    Task { await storeKit.restore() }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.smoke)
            }
        }
        .shrunkCard(radius: ShrunkTheme.Radius.lg, padding: ShrunkTheme.Spacing.md)
    }

    private func smallButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(Color.mist)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Section group

    private func sectionGroup<Content: View>(title: String, subtitle: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.sm) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .heavy))
                .tracking(0.8)
                .foregroundStyle(Color.smoke)
                .padding(.horizontal, ShrunkTheme.Spacing.sm)

            VStack(spacing: 0) {
                content()
            }
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous)
                    .stroke(Color.borderSoft, lineWidth: 0.5)
            )
            .shrunkElevation(ShrunkTheme.Elevation.whisper)

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.smoke)
                    .padding(.horizontal, ShrunkTheme.Spacing.sm)
                    .lineSpacing(2)
            }
        }
    }

    // MARK: - Positioning footer

    private var positioningFooter: some View {
        VStack(spacing: 4) {
            Text("They shrunk it. We caught them.")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(Color.shrunkRed)
            Text("Independent. No brand pays us. Ever.")
                .font(.system(size: 11))
                .foregroundStyle(Color.smoke)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, ShrunkTheme.Spacing.lg)
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

// MARK: - Settings rows

private struct SettingsRow: View {
    let icon: String
    let iconTint: Color
    let label: String
    let isLink: Bool
    let action: () -> Void

    init(icon: String, iconTint: Color, label: String, isLink: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        self.iconTint = iconTint
        self.label = label
        self.isLink = isLink
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: ShrunkTheme.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(iconTint.opacity(0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(iconTint)
                }
                Text(label)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Color.ink)
                Spacer()
                Image(systemName: isLink ? "arrow.up.right" : "chevron.right")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Color.smokeSoft)
            }
            .padding(.horizontal, ShrunkTheme.Spacing.md)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(Color.surface)
            .overlay(
                Rectangle()
                    .fill(Color.borderSoft)
                    .frame(height: 0.5),
                alignment: .bottom
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsValueRow: View {
    let icon: String
    let iconTint: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: ShrunkTheme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(iconTint.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(iconTint)
            }
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(Color.ink)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.smoke)
        }
        .padding(.horizontal, ShrunkTheme.Spacing.md)
        .padding(.vertical, 12)
        .overlay(
            Rectangle()
                .fill(Color.borderSoft)
                .frame(height: 0.5),
            alignment: .bottom
        )
    }
}

private struct SettingsShareRow: View {
    var body: some View {
        ShareLink(item: URL(string: "https://shrunk.app")!) {
            HStack(spacing: ShrunkTheme.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.shrunkRed.opacity(0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: "square.and.arrow.up.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.shrunkRed)
                }
                Text("Share Shrunk")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Color.smokeSoft)
            }
            .padding(.horizontal, ShrunkTheme.Spacing.md)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }
}
