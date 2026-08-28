import SwiftUI
import SwiftData

struct WatchlistView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var storeKit: StoreKitService

    @Query(sort: \WatchedProduct.addedAt, order: .reverse)
    private var watched: [WatchedProduct]

    @State private var vm: WatchlistViewModel?
    @State private var showPaywall: Bool = false
    @State private var showDashboard: Bool = false
    @State private var pendingRemoval: WatchedProduct?
    @State private var toastMessage: String?
    @State private var toastIsError = false

    var body: some View {
        NavigationStack {
            Group {
                if !storeKit.isProUser {
                    proGateView
                } else if watched.isEmpty {
                    emptyStateView
                } else {
                    listView
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Watchlist")
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Toast(
                    message: toastMessage,
                    icon: toastIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                    tint: toastIsError ? Color.shrunkRed : Color.verdictGood
                )
                    .padding(.bottom, 110)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: toastMessage)
        .task {
            if vm == nil {
                vm = WatchlistViewModel(service: WatchlistService(context: modelContext))
            }
            // Asking here rather than at launch: the user is looking at the
            // feature the permission is for. Already-answered prompts no-op.
            await NotificationScheduler.shared.requestPermissionAndRegister()
        }
        .sheet(isPresented: $showPaywall) {
            ProPaywallView()
        }
        .sheet(isPresented: $showDashboard) {
            SavingsDashboardView()
        }
        .sheet(item: Binding<ScannedBarcode?>(
            get: { vm?.presentedBarcode.map { ScannedBarcode(id: $0) } },
            set: { vm?.presentedBarcode = $0?.id }
        )) { wrapper in
            ResultView(barcode: wrapper.id)
        }
        .confirmationDialog(
            pendingRemoval.map { "Stop watching \($0.productName)?" } ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Stop watching", role: .destructive) {
                if let item = pendingRemoval {
                    // Only the success path gets the success toast; a failed
                    // delete says so (review S11).
                    if vm?.remove(item) == true {
                        showToast("Removed from watchlist")
                    } else {
                        showToast(vm?.errorMessage ?? "Couldn't remove this product.", isError: true)
                    }
                }
                pendingRemoval = nil
            }
            Button("Keep watching", role: .cancel) {
                pendingRemoval = nil
            }
        } message: {
            Text("You'll stop getting alerts when this product shrinks.")
        }
    }

    private func showToast(_ message: String, isError: Bool = false) {
        toastIsError = isError
        toastMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            await MainActor.run {
                if toastMessage == message { toastMessage = nil }
            }
        }
    }

    // MARK: - List

    private var listView: some View {
        List {
            Section {
                Button {
                    showDashboard = true
                } label: {
                    LabeledContent {
                        if vm?.isRefreshing == true {
                            ProgressView()
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(watched.count) watched")
                                .font(.headline)
                                .monospacedDigit()
                            Text(vm?.isRefreshing == true ? "Checking now…" : "Tap to see your savings")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            Section {
                ForEach(watched) { item in
                    WatchlistRow(
                        watched: item,
                        onTap: { vm?.presentedBarcode = item.barcode },
                        onToggleAlert: {
                            if vm?.toggleAlert(for: item) == false {
                                showToast(vm?.errorMessage ?? "Couldn't change this alert.", isError: true)
                            }
                        }
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingRemoval = item
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            } footer: {
                Text("Background-checked daily.")
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            guard let vm else { return }
            let detected = await vm.refresh()
            let total = watched.count
            let message = detected == 0
                ? "Checked \(total) product\(total == 1 ? "" : "s") · all stable"
                : "\(detected) size change\(detected == 1 ? "" : "s") to confirm"
            showToast(message)
        }
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("Nothing watched yet", systemImage: "eye.slash")
        } description: {
            Text("Watch products from any scan result. We'll alert you the moment one shrinks.")
        }
    }

    private var proGateView: some View {
        ContentUnavailableView {
            Label("Watching is a Pro feature", systemImage: "bell.badge")
        } description: {
            Text("Watch any product. We check Kroger in the background and alert you the moment it shrinks.")
        } actions: {
            Button("Unlock Shrunk Pro · \(storeKit.yearlyProduct?.displayPrice ?? "$14.99")") {
                showPaywall = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}
