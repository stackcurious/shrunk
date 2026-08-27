import SwiftUI
import UserNotifications

struct NotificationPreferencesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @AppStorage(NotificationPreferences.appStorageKey)
    private var rawPrefs: String = NotificationPreferences.default.encoded()

    @State private var prefs: NotificationPreferences = .default
    @State private var iosStatus: UNAuthorizationStatus = .notDetermined
    // Guards `.onChange(of: prefs)` from firing on the initial `.task` decode,
    // which would otherwise fire a spurious `POST /v1/devices` on every screen
    // open for any user whose stored prefs differ from `.default`.
    @State private var hasLoadedPrefs = false

    var body: some View {
        NavigationStack {
            Form {
                authorizationSection
                masterSection
                alertKindsSection
                quietHoursSection
                thresholdSection

                Section {
                    footer.listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .task {
            prefs = NotificationPreferences.decoded(rawPrefs)
            iosStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            hasLoadedPrefs = true
        }
        .onChange(of: prefs) { _, newValue in
            guard hasLoadedPrefs else { return }
            rawPrefs = newValue.encoded()
            // The crons read `devices.prefs`, so the switch has to reach the
            // Worker or it only silences local notifications.
            Task {
                await ShrunkAPIClient.shared.syncDevice(
                    deviceId: DeviceIdentity.current,
                    transactionJWS: ""
                )
            }
        }
    }

    // MARK: - iOS authorization

    @ViewBuilder
    private var authorizationSection: some View {
        let granted = iosStatus == .authorized || iosStatus == .provisional
        Section {
            HStack(spacing: 12) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(granted ? Color.verdictGood : Color.shrunkRed)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(granted ? "Notifications are on" : "Notifications need permission")
                        .font(.headline)
                    Text(granted
                         ? "iOS will deliver Shrunk alerts."
                         : "Without this, we can detect shrinks but can't tell you.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if !granted {
                    Button("Open") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            openURL(url)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Master

    private var masterSection: some View {
        Section {
            preferenceToggle(
                title: "Pause all alerts",
                subtitle: "Keep watching but don't notify me right now.",
                icon: "pause.circle.fill",
                tint: .shrunkRed,
                isOn: Binding(get: { prefs.paused }, set: { prefs.paused = $0 })
            )
        }
    }

    // MARK: - Alert kinds

    private var alertKindsSection: some View {
        Section("What fires") {
            preferenceToggle(
                title: "Size drops",
                subtitle: "A product you watch got smaller.",
                icon: "arrow.down.right.circle.fill",
                tint: .shrunkRed,
                isOn: Binding(get: { prefs.sizeDropEnabled }, set: { prefs.sizeDropEnabled = $0 })
            )
            preferenceToggle(
                title: "Price per unit up",
                subtitle: "Up 5% or more at your store.",
                icon: "chart.line.uptrend.xyaxis",
                tint: .verdictWarn,
                isOn: Binding(get: { prefs.priceHikeEnabled }, set: { prefs.priceHikeEnabled = $0 })
            )
            preferenceToggle(
                title: "Verified cases",
                subtitle: "We publish a confirmed shrink for something you watch.",
                icon: "checkmark.seal.fill",
                tint: .verdictGood,
                isOn: Binding(get: { prefs.verifiedCaseEnabled }, set: { prefs.verifiedCaseEnabled = $0 })
            )
            preferenceToggle(
                title: "Weekly digest",
                subtitle: "Monday summary of what shrank in your categories.",
                icon: "calendar",
                tint: .shrunkRed,
                isOn: Binding(get: { prefs.digestEnabled }, set: { prefs.digestEnabled = $0 })
            )
        }
    }

    // MARK: - Quiet hours

    private var quietHoursSection: some View {
        Section {
            preferenceToggle(
                title: "Quiet hours",
                subtitle: "Applies to on-device checks only — server alerts still arrive as they happen.",
                icon: "moon.zzz.fill",
                tint: .verdictWarn,
                isOn: Binding(get: { prefs.quietHoursEnabled }, set: { prefs.quietHoursEnabled = $0 })
            )

            if prefs.quietHoursEnabled {
                hourPickerRow(
                    label: "From",
                    hour: Binding(get: { prefs.quietHoursStartHour }, set: { prefs.quietHoursStartHour = $0 })
                )
                hourPickerRow(
                    label: "Until",
                    hour: Binding(get: { prefs.quietHoursEndHour }, set: { prefs.quietHoursEndHour = $0 })
                )
            }
        }
    }

    private func hourPickerRow(label: String, hour: Binding<Int>) -> some View {
        Picker(label, selection: hour) {
            ForEach(0..<24, id: \.self) { h in
                Text(NotificationPreferences.hourLabel(h)).tag(h)
            }
        }
    }

    // MARK: - Threshold

    private var thresholdSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent {
                    Text(thresholdLabel)
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(Color.shrunkRedDark)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Minimum shrink size")
                        Text("Ignore changes below this threshold.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Slider(
                    value: Binding(
                        get: { prefs.minimumShrinkPercent },
                        set: { prefs.minimumShrinkPercent = $0 }
                    ),
                    in: 0.01...0.20,
                    step: 0.01
                ) {
                    Text("Minimum shrink size")
                } minimumValueLabel: {
                    Text("1%").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("20%").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var thresholdLabel: String {
        String(format: "%.0f%%", prefs.minimumShrinkPercent * 100)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 4) {
            Text("Background sweeps run roughly daily, when iOS allows.")
            Text("You can also pull-to-refresh your Watchlist any time.")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Shared toggle row

    private func preferenceToggle(title: String, subtitle: String, icon: String, tint: Color, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: icon).foregroundStyle(tint)
            }
        }
    }
}
