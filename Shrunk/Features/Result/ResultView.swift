import SwiftUI
import UIKit

struct ResultView: View {
    let barcode: String
    let prebake: (product: ShrunkProduct, record: ShrinkRecord)?
    @StateObject private var vm = ResultViewModel()
    @EnvironmentObject private var storeKit: StoreKitService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var showWatchPaywall = false
    /// Set only by an explicit Watch tap. If the paywall purchase succeeds,
    /// this preserves the user's intent and finishes the action automatically.
    @State private var pendingWatchIntent = false
    @State private var showNotificationGuidance = false
    @State private var showAlternatives = false
    @State private var showShareCard = false
    /// Seeded from the watchlist on appear, so re-opening a watched product
    /// starts in the watched state instead of forgetting it (spec §2).
    @State private var isWatched = false
    @State private var showLabelCapture = false
    @State private var toastMessage: String?
    /// Rule 4 — a failed action reads as failure, not as a green tick.
    @State private var toastIsError = false
    /// `sensoryFeedback` triggers, replacing the hand-fired
    /// `UINotificationFeedbackGenerator` (spec §3, "Motion").
    @State private var successHaptic = 0
    @State private var errorHaptic = 0
    @AppStorage(StorePickerViewModel.storeNameKey) private var storeName: String = ""
    /// Side-by-side cells and label-beside-bar rows stop fitting somewhere
    /// around the first accessibility size; past that everything stacks.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(barcode: String) {
        self.barcode = barcode
        self.prebake = nil
    }

    init(prebakedProduct: ShrunkProduct, prebakedRecord: ShrinkRecord) {
        self.barcode = prebakedProduct.id
        self.prebake = (prebakedProduct, prebakedRecord)
    }

    var body: some View {
        NavigationStack {
            content
                // Without a title the inline bar is empty, so scrolled content
                // fades under it with nothing to replace it (review S1).
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .overlay(alignment: .bottom) { toastOverlay }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sensoryFeedback(.success, trigger: successHaptic)
        .sensoryFeedback(.error, trigger: errorHaptic)
        .task(id: barcode) {
            vm.isPro = storeKit.isProUser
            // Seeded before the first render of a `.loaded` state: `prebake`
            // sets `.loaded` synchronously, so reading the watchlist after it
            // would flash "Watch this product" for a frame on a product that
            // is already watched.
            isWatched = ((try? WatchlistService(context: modelContext).fetch(barcode: barcode)) ?? nil) != nil
            if let prebake { vm.prebake(product: prebake.product, record: prebake.record) }
            await vm.load(barcode: barcode)
            // A scan's ShrinkRecord is now final — spec §3.5 counts every
            // scanned product, not just watched ones (WatchlistService
            // dedupes so repeat views of the same size don't refile). Gated
            // to `prebake == nil`: a prebaked ResultView is a curated Browse
            // card (BrowseView passes `record.product`/`record` straight
            // from `trending.json`, pre-filtered to shrinks by
            // BrowseViewModel.applyFeed) — not something the user scanned,
            // so it must never file an alert or price a ledger entry.
            if prebake == nil, case .loaded(let product, let record) = vm.state {
                try? WatchlistService(context: modelContext).recordScannedShrink(product: product, record: record)
            }
        }
        .fullScreenCover(isPresented: $showLabelCapture) {
            LabelCaptureView(gtin: barcode) { result in
                toastIsError = false
                toastMessage = ContributeViewModel.toastMessage(for: result)
                Task { await vm.reload(barcode: barcode) }
            }
        }
        .onChange(of: storeKit.isProUser) { _, isPro in
            // Minor #4: lift (or re-apply) the alternatives cap the moment
            // Pro status changes, rather than waiting for a reload.
            Task { await vm.refreshAlternatives(isPro: isPro) }
            switch ResultViewModel.resolvePendingWatch(
                isPending: pendingWatchIntent,
                isPro: isPro,
                isAlreadyWatched: isWatched
            ) {
            case .add:
                pendingWatchIntent = false
                if case .loaded(let product, let record) = vm.state {
                    addToWatchlist(product: product, record: record)
                }
            case .clear:
                pendingWatchIntent = false
            case .wait:
                break
            }
        }
        .alert("Watch saved", isPresented: $showNotificationGuidance) {
            Button("Open Notification Settings") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Not now", role: .cancel) { }
        } message: {
            Text("This product is on your watchlist. Turn on notifications so Shrunk can tell you when it changes.")
        }
    }

    /// The bar condenses to whatever the screen is about; `.inline` keeps it a
    /// single line, and the hero below repeats it at full size the way any
    /// iOS detail sheet does.
    private var navigationTitle: String {
        if case .loaded(let product, _) = vm.state, !product.name.isEmpty {
            return product.name
        }
        return "Scan result"
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toastMessage {
            Toast(
                message: toastMessage,
                icon: toastIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                tint: toastIsError ? Color.shrunkRed : Color.verdictGood
            )
                .padding(.bottom, 32)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: toastMessage) {
                    try? await Task.sleep(nanoseconds: 2_800_000_000)
                    withAnimation { self.toastMessage = nil }
                }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Close")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .loading:
            loadingView
        case .loaded(let product, let record):
            loadedView(product: product, record: record)
        case .notFound(let code):
            notFoundView(barcode: code)
        case .error(let message):
            errorView(message: message)
        }
    }

    // MARK: - Loaded — the money screen

    @ViewBuilder
    private func loadedView(product: ShrunkProduct, record: ShrinkRecord) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                heroSection(product: product, record: record)
                comparisonRow(record: record)
                if product.needsConfirmation || vm.liveSizeMismatch {
                    confirmationCard
                        .padding(.horizontal, 20)
                }
                costPerOzSection(record: record)
                LivePricePanel(state: vm.livePrice, storeName: storeName)
                cheapestAlternativeCallout(record: record)
                if product.sizeHistory.count >= 2 {
                    ShrinkHistoryChart(
                        history: product.sizeHistory,
                        isPro: storeKit.isProUser,
                        onUpgrade: { showWatchPaywall = true }
                    )
                    .padding(.horizontal, 20)
                }
                ctaSection(product: product, record: record)
                    .padding(.horizontal, 20)
            }
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            primaryActionBar(product: product, record: record)
        }
        .sheet(isPresented: $showWatchPaywall, onDismiss: {
            if !storeKit.isProUser { pendingWatchIntent = false }
        }) { ProPaywallView() }
        .sheet(isPresented: $showAlternatives) {
            AlternativesView(product: product, record: record, result: vm.alternativesResult)
        }
        .sheet(isPresented: $showShareCard) {
            ShareCardView(record: record, product: product)
        }
    }

    // MARK: - Hero (meter + product header)

    private func heroSection(product: ShrunkProduct, record: ShrinkRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ProductImage(url: product.imageURL, size: 64, cornerRadius: 12)

                VStack(alignment: .leading, spacing: 3) {
                    Text(product.name)
                        .font(.title2.bold())
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    let provenance = [product.brand, product.category]
                        .filter { !$0.isEmpty }
                        .joined(separator: " · ")
                    if !provenance.isEmpty {
                        Text(provenance)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if ShareCardRenderer.canShare(record: record) {
                    Button {
                        showShareCard = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Share result")
                }
            }

            Divider()

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verdictEyebrow(for: record))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(verdictHeadline(for: record))
                        .font(.title.bold())
                        .monospacedDigit()
                        .foregroundStyle(verdictTextColor(record.verdict))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verdictDetail(for: record))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if record.currentSize != nil {
                    ShrinkMeter(
                        percentChange: record.shrinkPercent,
                        verdict: record.verdict,
                        size: .compact
                    )
                } else {
                    Image(systemName: "camera.viewfinder")
                        .font(.title.bold())
                        .foregroundStyle(Color.shrunkRed)
                        .frame(width: 72, height: 72)
                        .background(Color.shrunkRedLight, in: Circle())
                        .accessibilityHidden(true)
                }
            }

            Label(evidenceLine(for: record), systemImage: "checkmark.shield")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .groupedCard()
        .padding(.horizontal, 20)
    }

    // MARK: - Then → Now comparison row

    /// A Then→Now row is a claim that the two sizes are comparable.
    /// `ShrinkDetector` also emits `.insufficientData` from the zero-quantity
    /// guard and the cross-source plausibility clamp, and both keep a
    /// `previousSize` we have just decided not to trust — drawing it beside
    /// "No shrink on record" contradicts the headline, and in the zero case
    /// prints "0 ml → 946.4 ml" (review S13). Those states fall through to the
    /// single "Current size" card instead.
    @ViewBuilder
    private func comparisonRow(record: ShrinkRecord) -> some View {
        if record.verdict != .insufficientData,
           let prev = record.previousSize, let curr = record.currentSize {
            // Two cells side by side cannot hold "946.4 ml" at AX5 without
            // truncating the one number the screen exists for, so past the
            // first accessibility size the arrow turns downward and they stack.
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 8))
                : AnyLayout(HStackLayout(spacing: 12))
            layout {
                quantityCell(label: "Then",
                             value: prev.quantity.formattedQuantity(unit: prev.unit),
                             date: prev.date,
                             accent: .primary,
                             tint: Color(.tertiarySystemFill))
                Image(systemName: dynamicTypeSize.isAccessibilitySize ? "arrow.down" : "arrow.right")
                    .font(.headline)
                    .foregroundStyle(verdictTextColor(record.verdict))
                quantityCell(label: "Now",
                             value: curr.quantity.formattedQuantity(unit: curr.unit),
                             date: curr.date,
                             accent: verdictTextColor(record.verdict),
                             tint: verdictTintColor(record.verdict))
            }
            .padding(.horizontal, 20)
        } else if let curr = record.currentSize {
            VStack(alignment: .leading, spacing: 4) {
                Text("Current size")
                    .font(.headline)
                Text(curr.quantity.formattedQuantity(unit: curr.unit))
                    .font(.title.bold())
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .groupedCard()
            .padding(.horizontal, 20)
        }
    }

    private func quantityCell(label: String, value: String, date: Date, accent: Color, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.bold())
                .monospacedDigit()
                .foregroundStyle(accent)
                // Wraps instead of shrinking away: "946.4 ml" at AX5 used to
                // truncate to "946.4…", which is the payload of the screen.
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .fixedSize(horizontal: false, vertical: true)
            Text(date, format: .dateTime.year())
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Shown when the live store size disagrees with our latest observation
    /// (spec §4 step 4). Phase 3 sets `needsConfirmation`; the flow is live now.
    private var confirmationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Size unconfirmed", systemImage: "camera.viewfinder")
                .font(.headline)
                .foregroundStyle(Color.verdictWarnDeep)
            Text("The size we're showing might be out of date. A photo of the net-weight line settles it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ShrunkButton("Confirm with a label photo", icon: "camera.fill", variant: .ghost) {
                showLabelCapture = true
            }
        }
        .groupedCard()
    }

    // MARK: - Cost-per-oz

    @ViewBuilder
    private func costPerOzSection(record: ShrinkRecord) -> some View {
        if record.costPerUnitNow == nil { EmptyView() } else {
            VStack(alignment: .leading, spacing: 12) {
                // When `costPerUnitNow` came from `product.priceHistory`
                // (`price_snapshots` — Kroger-derived), this card must carry the
                // same attribution `LivePricePanel` does (spec §9, Phase 3 review
                // I6). It must NOT show attribution when the price fell back to
                // `product.currentPrice` with no snapshot history — e.g. curated
                // Browse cards, whose price is not Kroger data (I6 regression fix).
                HStack(alignment: .firstTextBaseline) {
                    Text(record.costPerUnitThen == nil ? "Current unit price" : "Observed unit-price change")
                        .font(.headline)
                    Spacer(minLength: 8)
                    // One attribution per screen: when the store card below is
                    // already carrying it, this card doesn't repeat it (N7).
                    if record.priceIsFromStoreSnapshot, !livePricePanelCarriesAttribution {
                        Text(LivePrice.attribution)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let then = record.costPerUnitThen, let now = record.costPerUnitNow, then > 0 {
                    let pct = ((now - then) / then) * 100
                    let denom = max(then, now)
                    // The rows used to live inside a `GeometryReader` pinned to
                    // 64 pt: at an accessibility size the content grew past it
                    // and the "% more per ounce" line was drawn on top of the
                    // bars. Each row now measures itself (review B3).
                    VStack(alignment: .leading, spacing: 8) {
                        costBarRow(label: "Earlier", value: then.formattedCostPerUnit(),
                                   fraction: then / denom, fill: Color(.systemFill))
                        costBarRow(label: "Current", value: now.formattedCostPerUnit(),
                                   fraction: now / denom, fill: Color.shrunkRed)
                    }

                    Text(unitCostChangeLine(percent: pct, record: record))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(pct > 0 ? Color.shrunkRedDark : Color.verdictGoodDeep)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let now = record.costPerUnitNow {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(now.formattedCostPerUnit())
                            .font(.title.bold())
                            .monospacedDigit()
                        Text(unitCostShortLabel(for: record))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text("We don't have a historical price to compare against — yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .groupedCard()
            .padding(.horizontal, 20)
        }
    }

    /// Label and figure sit on their own line above the bar, so neither is
    /// boxed into a fixed width ("Then" used to truncate to "…" inside a 40 pt
    /// frame). The bar itself is a graphic and keeps its 22 pt height at every
    /// text size — only the `GeometryReader` that measures its width is fixed.
    private func costBarRow(label: String, value: String, fraction: Double, fill: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value)
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.tertiarySystemFill))
                    Capsule()
                        .fill(fill)
                        .frame(width: max(8, geo.size.width * CGFloat(fraction)))
                }
            }
            .frame(height: 22)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - CTAs

    /// Spec §2's action column. The single-snapshot and no-size states lead
    /// with the action that moves *them* forward — watching, or the label photo
    /// that makes watching possible — rather than the alternatives button the
    /// shrink screen leads with.
    private func primaryActionBar(product: ShrunkProduct, record: ShrinkRecord) -> some View {
        let outcome = ResultViewModel.watchOutcome(
            record: record, isPro: storeKit.isProUser, isAlreadyWatched: isWatched
        )
        return VStack(spacing: 0) {
            Divider()
            Group {
                if record.verdict.isShrink && outcome != .needsLabel {
                    ShrunkButton("Compare alternatives", icon: "arrow.left.arrow.right") {
                        showAlternatives = true
                    }
                } else {
                    watchButton(
                        outcome: outcome,
                        product: product,
                        record: record,
                        watchTitle: record.verdict == .insufficientData
                            ? "Watch for the next change"
                            : "Watch this product",
                        variant: .primary
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial)
    }

    /// Secondary actions stay in the scroll content; the one decisive next
    /// step is pinned above the sheet edge by `primaryActionBar`.
    private func ctaSection(product: ShrunkProduct, record: ShrinkRecord) -> some View {
        let outcome = ResultViewModel.watchOutcome(
            record: record, isPro: storeKit.isProUser, isAlreadyWatched: isWatched
        )
        return VStack(spacing: 8) {
            if outcome == .needsLabel {
                ShrunkButton("Compare alternatives", icon: "arrow.left.arrow.right", variant: .ghost) {
                    showAlternatives = true
                }
            } else if record.verdict == .insufficientData {
                ShrunkButton("Compare alternatives", icon: "arrow.left.arrow.right", variant: .ghost) {
                    showAlternatives = true
                }
                ShrunkButton("Confirm size with a label", icon: "camera", variant: .ghost) {
                    showLabelCapture = true
                }
            } else if record.verdict == .unchanged || record.verdict == .grew {
                ShrunkButton("Compare alternatives", icon: "arrow.left.arrow.right", variant: .ghost) {
                    showAlternatives = true
                }
            } else {
                watchButton(outcome: outcome, product: product, record: record, variant: .ghost)
            }
        }
    }

    /// One button for every `WatchOutcome`: the outcome alone decides the
    /// title, the icon and what the tap does. `watchTitle` only names the
    /// actually-watchable cases, which is the one thing that differs between
    /// the §2 rows.
    private func watchButton(
        outcome: ResultViewModel.WatchOutcome,
        product: ShrunkProduct,
        record: ShrinkRecord,
        watchTitle: String = "Watch this product",
        variant: ShrunkButtonVariant
    ) -> some View {
        ShrunkButton(
            Self.watchButtonTitle(outcome, watchTitle: watchTitle),
            icon: Self.watchButtonIcon(outcome),
            variant: variant
        ) {
            handleWatch(outcome: outcome, product: product, record: record)
        }
        .disabled(outcome == .alreadyWatched)
    }

    private static func watchButtonTitle(
        _ outcome: ResultViewModel.WatchOutcome,
        watchTitle: String
    ) -> String {
        switch outcome {
        case .alreadyWatched:  return "On your watchlist"
        case .needsLabel:      return "Snap the label to start tracking"
        case .paywall, .watch: return watchTitle
        }
    }

    private static func watchButtonIcon(_ outcome: ResultViewModel.WatchOutcome) -> String {
        switch outcome {
        case .alreadyWatched:  return "bell.badge.fill"
        case .needsLabel:      return "camera.fill"
        case .paywall, .watch: return "bell"
        }
    }

    /// Rule 4 — every branch does something the user can see. The old version
    /// of this had two silent `return`s in it.
    private func handleWatch(
        outcome: ResultViewModel.WatchOutcome,
        product: ShrunkProduct,
        record: ShrinkRecord
    ) {
        switch outcome {
        case .alreadyWatched:
            break                                   // button is disabled
        case .needsLabel:
            showLabelCapture = true
        case .paywall:
            pendingWatchIntent = true
            showWatchPaywall = true
        case .watch:
            addToWatchlist(product: product, record: record)
        }
    }

    private func addToWatchlist(product: ShrunkProduct, record: ShrinkRecord) {
        do {
            try WatchlistService(context: modelContext).add(product: product, record: record)
            isWatched = true
            toastIsError = false
            withAnimation {
                toastMessage = "Added \(product.name) to your watchlist"
            }
            successHaptic += 1
            Task { await configureNotificationsAfterWatch() }
        } catch {
            toastIsError = true
            withAnimation {
                toastMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Couldn't add this to your watchlist."
            }
            errorHaptic += 1
        }
    }

    private func configureNotificationsAfterWatch() async {
        let scheduler = NotificationScheduler.shared
        let status = await scheduler.authorizationStatus()
        switch NotificationScheduler.watchFollowUp(for: status) {
        case .requestPermission:
            if !(await scheduler.requestPermissionAndRegister()) {
                showNotificationGuidance = true
            }
        case .register:
            scheduler.registerForRemoteNotifications()
        case .guideToSettings:
            showNotificationGuidance = true
        }
    }

    // MARK: - Loading / not-found / error

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Checking product history…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private func notFoundView(barcode: String) -> some View {
        ContentUnavailableView {
            // §2's headline, verbatim. The call to action it used to carry is
            // the button directly below it, and the toolbar ✕ is the Close
            // this used to duplicate (review N2).
            Label("Not in our database yet", systemImage: "camera.viewfinder")
        } description: {
            Text("Barcode \(barcode). One photo of the net-weight line adds it for every Shrunk user.")
                .monospacedDigit()
        } actions: {
            Button {
                showLabelCapture = true
            } label: {
                Label("Snap the label", systemImage: "camera.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private func errorView(message: String) -> some View {
        EmptyStateView(
            icon: "wifi.exclamationmark",
            title: "Couldn't load this product",
            message: message,
            actionTitle: "Try again",
            action: { Task { await vm.load(barcode: barcode) } }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Helpers

    /// `LivePricePanel` prints "Prices from Kroger" only when it has a loaded
    /// row to attribute, so that is exactly when the per-ounce card above it
    /// can stay quiet.
    private var livePricePanelCarriesAttribution: Bool {
        if case .loaded = vm.livePrice { return true }
        return false
    }

    private func verdictEyebrow(for record: ShrinkRecord) -> String {
        switch record.verdict {
        case .significantShrink, .moderateShrink, .minorShrink: return "Documented downsizing"
        case .unchanged: return "Package history"
        case .grew: return "Package history"
        case .insufficientData: return record.currentSize == nil ? "Help verify this product" : "Starting point"
        }
    }

    private func verdictHeadline(for record: ShrinkRecord) -> String {
        switch record.verdict {
        case .significantShrink, .moderateShrink, .minorShrink:
            return "\(abs(record.shrinkPercent).formattedPercent(decimals: record.shrinkPercent > -10 ? 1 : 0)) smaller"
        case .unchanged: return "Size held steady"
        case .grew: return "Package got larger"
        case .insufficientData: return record.currentSize == nil ? "Size not verified" : "Baseline established"
        }
    }

    private func verdictDetail(for record: ShrinkRecord) -> String {
        switch record.verdict {
        case .significantShrink, .moderateShrink, .minorShrink:
            return "Two dated package sizes confirm a reduction. Price history is evaluated separately."
        case .unchanged:
            return "Comparable observations show the package holding its size."
        case .grew:
            return "The latest documented package size is larger than the previous one."
        case .insufficientData:
            if let fact = sizeFactLine(for: record) {
                return "\(fact). Watch it and we'll compare the next verified change."
            }
            return "Photograph the net-weight line to create a reliable starting point."
        }
    }

    private func evidenceLine(for record: ShrinkRecord) -> String {
        let records = [record.previousSize, record.currentSize].compactMap { $0 }
        guard !records.isEmpty else { return "No package-size evidence yet" }
        let sources = Array(Set(records.map { sourceName($0.source) })).sorted()
        let count = records.count
        return "\(count) dated size record\(count == 1 ? "" : "s") · \(sources.joined(separator: " + "))"
    }

    private func sourceName(_ source: String) -> String {
        switch source.lowercased() {
        case "fdc", "usda": return "USDA data"
        case "off", "openfoodfacts", "openfoodfacts_import": return "Open Food Facts"
        case "kroger": return "Kroger listing"
        case "crowd", "user_report": return "Community label"
        case "curated", "trending_feed": return "Published documentation"
        default: return "Recorded package data"
        }
    }

    private func unitCostChangeLine(percent: Double, record: ShrinkRecord) -> String {
        let direction = percent >= 0 ? "more" : "less"
        return "\(abs(percent).formattedPercent(decimals: 1)) \(direction) \(unitCostLongLabel(for: record))"
    }

    private func unitCostShortLabel(for record: ShrinkRecord) -> String {
        switch record.currentSize?.unitKind {
        case "volume": return "per fl oz"
        case "count": return "each"
        default: return "per oz"
        }
    }

    private func unitCostLongLabel(for record: ShrinkRecord) -> String {
        switch record.currentSize?.unitKind {
        case "volume": return "per fluid ounce"
        case "count": return "per item"
        default: return "per ounce"
        }
    }

    /// "32 fl oz, first seen Feb 2018" — or "28 fl oz at Kroger today" when the
    /// size was adopted from the live store row (spec §2, rule 5). Only the
    /// single-snapshot state needs it; the shrink states already draw a
    /// Then→Now row.
    private func sizeFactLine(for record: ShrinkRecord) -> String? {
        // Gated on the *shape of the data*, not the verdict: `.insufficientData`
        // also covers records that do have a previous size we chose not to
        // trust, and "first seen …" alongside a rejected earlier observation is
        // a claim we can't make (review S13).
        guard record.previousSize == nil, let size = record.currentSize else { return nil }
        let quantity = size.quantity.formattedQuantity(unit: size.unit)
        if vm.adoptedLiveSize {
            let store = storeName.isEmpty ? "Kroger" : storeName
            return "\(quantity) at \(store) today"
        }
        return "\(quantity), first seen \(size.date.formatted(.dateTime.month(.abbreviated).year()))"
    }

    /// The cheapest store alternative that actually beats what the scanned
    /// product costs per normalized unit. Curated rows carry no `costPerUnit`, so they
    /// can never produce a false "cheaper" claim.
    private func cheapestAlternative(for record: ShrinkRecord) -> Alternative? {
        guard let scanned = record.costPerUnitNow, scanned > 0 else { return nil }
        return vm.alternativesResult.alternatives
            .filter { $0.source == .store }
            .compactMap { alt -> (Alternative, Double)? in
                guard let cost = alt.costPerUnit, cost < scanned else { return nil }
                return (alt, cost)
            }
            .min { $0.1 < $1.1 }?.0
    }

    /// §2 lists this callout only on the single-snapshot row. On a shrink or
    /// unchanged/grew screen it would sit directly above that row's own
    /// alternatives CTA, so it stays scoped to the state the spec gives it to.
    @ViewBuilder
    private func cheapestAlternativeCallout(record: ShrinkRecord) -> some View {
        if record.verdict == .insufficientData, let best = cheapestAlternative(for: record) {
            Button {
                showAlternatives = true
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Label("Cheapest \(unitCostLongLabel(for: record)) at your store", systemImage: "arrow.down.circle.fill")
                            .font(.headline)
                            .foregroundStyle(Color.verdictGoodDeep)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Text(best.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    Text(best.verdict)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .groupedCard()
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
        }
    }

    private func verdictTextColor(_ v: ShrinkRecord.ShrinkVerdict) -> Color {
        switch v {
        case .significantShrink: return .shrunkRedDark
        case .moderateShrink, .minorShrink: return .verdictWarnDeep
        case .unchanged, .grew: return .verdictGoodDeep
        // `.secondary` on `tertiarySystemFill` is 3.11:1 — under AA for the
        // `.subheadline.semibold` verdict pill that ~98.5 % of scans land on
        // (review S7). The full label colour on the same fill clears it.
        case .insufficientData: return Color(.label)
        }
    }

    private func verdictTintColor(_ v: ShrinkRecord.ShrinkVerdict) -> Color {
        switch v {
        case .significantShrink: return .shrunkRedLight
        case .moderateShrink, .minorShrink: return .verdictWarnTint
        case .unchanged, .grew: return .verdictGoodTint
        case .insufficientData: return Color(.tertiarySystemFill)
        }
    }

    private static func compact(_ value: Double) -> String {
        if value == value.rounded() {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}
