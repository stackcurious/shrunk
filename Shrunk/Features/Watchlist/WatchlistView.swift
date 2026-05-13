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

    var body: some View {
        Group {
            if !storeKit.isProUser {
                proGateView
            } else if watched.isEmpty {
                emptyStateView
            } else {
                listView
            }
        }
        .background(Color.paper.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Toast(message: toastMessage)
                    .padding(.bottom, 110)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: toastMessage)
        .task {
            if vm == nil {
                vm = WatchlistViewModel(service: WatchlistService(context: modelContext))
            }
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
                    vm?.remove(item)
                    showToast("Removed from watchlist")
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

    private func showToast(_ message: String) {
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
        ScrollView {
            VStack(spacing: ShrunkTheme.Spacing.lg) {
                ShrunkPageHeader(title: "Watchlist", subtitle: "Background-checked daily")
                heroStrip
                VStack(spacing: 8) {
                    ForEach(watched) { item in
                        WatchlistRow(
                            watched: item,
                            onTap: { vm?.presentedBarcode = item.barcode },
                            onToggleAlert: { vm?.toggleAlert(for: item) }
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingRemoval = item
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, ShrunkTheme.Spacing.lg)
            }
            .padding(.bottom, 100)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            guard let vm else { return }
            let results = await vm.refresh()
            let detected = results.count
            let total = watched.count
            let message: String
            if detected == 0 {
                message = "Checked \(total) product\(total == 1 ? "" : "s") · all stable"
            } else {
                message = "\(detected) new shrink\(detected == 1 ? "" : "s") detected!"
            }
            showToast(message)
        }
    }

    private var heroStrip: some View {
        Button {
            showDashboard = true
        } label: {
            HStack(spacing: ShrunkTheme.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(LinearGradient.shrunkRedDiagonal)
                        .frame(width: 64, height: 64)
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                }
                .shrunkElevation(ShrunkTheme.Elevation.card)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(watched.count) watched")
                        .font(.shrunkTitle)
                        .foregroundStyle(Color.ink)
                    Text(vm?.isRefreshing == true ? "Checking now…" : "Tap to see your savings")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.smoke)
                }
                Spacer()
                if vm?.isRefreshing == true {
                    ProgressView().controlSize(.regular).tint(Color.shrunkRed)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(Color.smokeSoft)
                }
            }
            .shrunkCard(radius: ShrunkTheme.Radius.lg, padding: ShrunkTheme.Spacing.md)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, ShrunkTheme.Spacing.lg)
    }

    private var emptyStateView: some View {
        VStack(spacing: ShrunkTheme.Spacing.lg) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.shrunkRedLight)
                    .frame(width: 120, height: 120)
                Image(systemName: "bell.badge")
                    .font(.system(size: 50, weight: .light))
                    .foregroundStyle(Color.shrunkRed)
            }
            VStack(spacing: 8) {
                Text("Nothing watched yet")
                    .font(.shrunkLargeTitle)
                    .foregroundStyle(Color.ink)
                Text("Watch products from any scan result. We'll alert you the moment one shrinks.")
                    .font(.shrunkBody)
                    .foregroundStyle(Color.smoke)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, ShrunkTheme.Spacing.lg)
                    .lineSpacing(2)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var proGateView: some View {
        VStack(spacing: ShrunkTheme.Spacing.lg) {
            Spacer()
            ZStack {
                Circle()
                    .fill(LinearGradient.shrunkRedDiagonal)
                    .frame(width: 110, height: 110)
                    .shrunkElevation(ShrunkTheme.Elevation.float)
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(.white)
            }
            VStack(spacing: 8) {
                Text("Watching is a Pro feature")
                    .font(.shrunkLargeTitle)
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                Text("Watch any product. We check Open Food Facts in the background and alert you the moment it shrinks.")
                    .font(.shrunkBody)
                    .foregroundStyle(Color.smoke)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, ShrunkTheme.Spacing.lg)
                    .lineSpacing(2)
            }
            ShrunkButton("Unlock Shrunk Pro · \(storeKit.product?.displayPrice ?? "$9.99")", icon: "lock.open.fill") {
                showPaywall = true
            }
            .padding(.horizontal, ShrunkTheme.Spacing.lg)
            .padding(.top, ShrunkTheme.Spacing.sm)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
