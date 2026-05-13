import SwiftUI
import UserNotifications

struct NotificationPreferencesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @AppStorage(NotificationPreferences.appStorageKey)
    private var rawPrefs: String = NotificationPreferences.default.encoded()

    @State private var prefs: NotificationPreferences = .default
    @State private var iosStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ShrunkTheme.Spacing.lg) {
                    iosAuthorizationCard
                    masterControlsCard
                    quietHoursCard
                    thresholdCard
                    footer
                }
                .padding(.horizontal, ShrunkTheme.Spacing.lg)
                .padding(.vertical, ShrunkTheme.Spacing.lg)
            }
            .scrollIndicators(.hidden)
            .background(Color.paper.ignoresSafeArea())
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(Color.ink)
                            .frame(width: 32, height: 32)
                            .background(Color.mist)
                            .clipShape(Circle())
                    }
                }
            }
        }
        .task {
            prefs = NotificationPreferences.decoded(rawPrefs)
            iosStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
        .onChange(of: prefs) { _, newValue in
            rawPrefs = newValue.encoded()
        }
    }

    // MARK: - iOS authorization card

    private var iosAuthorizationCard: some View {
        let granted = iosStatus == .authorized || iosStatus == .provisional
        return HStack(spacing: ShrunkTheme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(granted ? Color.verdictGoodTint : Color.shrunkRedLight)
                    .frame(width: 44, height: 44)
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(granted ? Color.verdictGood : Color.shrunkRed)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(granted ? "Notifications are on" : "Notifications need permission")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(Color.ink)
                Text(granted ? "iOS will deliver Shrunk alerts." : "Without this, we can detect shrinks but can't tell you.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.smoke)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if !granted {
                Button("Open") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        openURL(url)
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.shrunkRed)
            }
        }
        .padding(ShrunkTheme.Spacing.md)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous)
                .stroke(Color.borderSoft, lineWidth: 0.5)
        )
        .shrunkElevation(ShrunkTheme.Elevation.whisper)
    }

    // MARK: - Master controls

    private var masterControlsCard: some View {
        VStack(spacing: 0) {
            preferenceToggle(
                title: "Pause all alerts",
                subtitle: "Keep watching but don't notify me right now.",
                icon: "pause.circle.fill",
                tint: .shrunkRed,
                isOn: Binding(get: { prefs.paused }, set: { prefs.paused = $0 })
            )
        }
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous)
                .stroke(Color.borderSoft, lineWidth: 0.5)
        )
        .shrunkElevation(ShrunkTheme.Elevation.whisper)
    }

    // MARK: - Quiet hours

    private var quietHoursCard: some View {
        VStack(spacing: 0) {
            preferenceToggle(
                title: "Quiet hours",
                subtitle: "Don't notify me during this window.",
                icon: "moon.zzz.fill",
                tint: .verdictWarn,
                isOn: Binding(get: { prefs.quietHoursEnabled }, set: { prefs.quietHoursEnabled = $0 })
            )

            if prefs.quietHoursEnabled {
                Divider().overlay(Color.borderSoft)
                hourPickerRow(
                    label: "From",
                    hour: Binding(get: { prefs.quietHoursStartHour }, set: { prefs.quietHoursStartHour = $0 })
                )
                Divider().overlay(Color.borderSoft)
                hourPickerRow(
                    label: "Until",
                    hour: Binding(get: { prefs.quietHoursEndHour }, set: { prefs.quietHoursEndHour = $0 })
                )
            }
        }
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous)
                .stroke(Color.borderSoft, lineWidth: 0.5)
        )
        .shrunkElevation(ShrunkTheme.Elevation.whisper)
    }

    private func hourPickerRow(label: String, hour: Binding<Int>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(Color.ink)
                .padding(.leading, ShrunkTheme.Spacing.md)
            Spacer()
            Picker(label, selection: hour) {
                ForEach(0..<24, id: \.self) { h in
                    Text(NotificationPreferences.hourLabel(h)).tag(h)
                }
            }
            .pickerStyle(.menu)
            .tint(Color.shrunkRed)
            .padding(.trailing, 4)
        }
        .padding(.vertical, 10)
    }

    // MARK: - Threshold

    private var thresholdCard: some View {
        VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.sm) {
            HStack(spacing: ShrunkTheme.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.shrunkRedLight)
                        .frame(width: 40, height: 40)
                    Image(systemName: "ruler.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.shrunkRed)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Minimum shrink size")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.ink)
                    Text("Ignore changes below this threshold.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.smoke)
                }
                Spacer()
                Text(thresholdLabel)
                    .font(.system(size: 16, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Color.shrunkRedDark)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.shrunkRedLight)
                    .clipShape(Capsule())
            }
            Slider(
                value: Binding(
                    get: { prefs.minimumShrinkPercent },
                    set: { prefs.minimumShrinkPercent = $0 }
                ),
                in: 0.01...0.20,
                step: 0.01
            )
            .tint(Color.shrunkRed)
            HStack {
                Text("1%").font(.system(size: 11)).foregroundStyle(Color.smokeSoft)
                Spacer()
                Text("20%").font(.system(size: 11)).foregroundStyle(Color.smokeSoft)
            }
        }
        .padding(ShrunkTheme.Spacing.md)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous)
                .stroke(Color.borderSoft, lineWidth: 0.5)
        )
        .shrunkElevation(ShrunkTheme.Elevation.whisper)
    }

    private var thresholdLabel: String {
        String(format: "%.0f%%", prefs.minimumShrinkPercent * 100)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 6) {
            Text("Background sweeps run roughly daily, when iOS allows.")
                .font(.system(size: 11))
                .foregroundStyle(Color.smokeSoft)
            Text("You can also pull-to-refresh your Watchlist any time.")
                .font(.system(size: 11))
                .foregroundStyle(Color.smokeSoft)
        }
        .multilineTextAlignment(.center)
        .padding(.top, ShrunkTheme.Spacing.md)
    }

    // MARK: - Shared toggle row

    private func preferenceToggle(title: String, subtitle: String, icon: String, tint: Color, isOn: Binding<Bool>) -> some View {
        HStack(spacing: ShrunkTheme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.smoke)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Color.shrunkRed)
        }
        .padding(ShrunkTheme.Spacing.md)
    }
}
