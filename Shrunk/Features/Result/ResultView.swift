import SwiftUI

struct ResultView: View {
    let barcode: String
    let prebake: (product: ShrunkProduct, record: ShrinkRecord)?
    @StateObject private var vm = ResultViewModel()
    @EnvironmentObject private var storeKit: StoreKitService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var showWatchPaywall = false
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
        }
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
        .sheet(isPresented: $showWatchPaywall) { ProPaywallView() }
        .sheet(isPresented: $showAlternatives) {
            AlternativesView(product: product, record: record, result: vm.alternativesResult)
        }
        .sheet(isPresented: $showShareCard) {
            ShareCardView(record: record, product: product)
        }
    }

    // MARK: - Hero (meter + product header)

    private func heroSection(product: ShrunkProduct, record: ShrinkRecord) -> some View {
        VStack(spacing: 16) {
            ShrinkMeter(
                percentChange: record.shrinkPercent,
                verdict: record.verdict,
                size: .hero
            )
            .padding(.top, 8)

            if product.imageURL != nil {
                ProductImage(url: product.imageURL, size: 88, cornerRadius: 14)
                    .padding(.top, -8)
            }

            VStack(spacing: 6) {
                Text(product.name)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)

                HStack(spacing: 6) {
                    if !product.brand.isEmpty {
                        Text(product.brand)
                    }
                    if !product.brand.isEmpty && !product.category.isEmpty {
                        Text("·")
                    }
                    if !product.category.isEmpty {
                        Text(product.category)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                if let line = bannerSubline(for: record) {
                    Text(line)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(verdictTextColor(record.verdict))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(verdictTintColor(record.verdict), in: Capsule())
                        .padding(.top, 4)
                }

                // Rule 1 — every loaded result states at least one concrete
                // fact. For the 98.5 % of products with a single snapshot that
                // fact is the size itself and when we first saw it.
                if let fact = sizeFactLine(for: record) {
                    Text(fact)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 20)

            // Nothing to share in the no-size state: there is no verdict, and
            // ShareCardView's Then→Now block guards on `previousSize`, so the
            // card would render with no sizes on it at all. §2's no-size row
            // lists no Share secondary either.
            if record.currentSize != nil {
                Button {
                    showShareCard = true
                } label: {
                    Label("Share verdict", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
    }

    // MARK: - Then → Now comparison row

    @ViewBuilder
    private func comparisonRow(record: ShrinkRecord) -> some View {
        if let prev = record.previousSize, let curr = record.currentSize {
            HStack(spacing: 12) {
                quantityCell(label: "Then",
                             value: prev.quantity.formattedQuantity(unit: prev.unit),
                             date: prev.date,
                             accent: .primary,
                             tint: Color(.tertiarySystemFill))
                Image(systemName: "arrow.right")
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
                .lineLimit(1)
                .minimumScaleFactor(0.6)
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
                    Text("Real cost per ounce")
                        .font(.headline)
                    Spacer(minLength: 8)
                    if record.priceIsFromStoreSnapshot {
                        Text(LivePrice.attribution)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let then = record.costPerUnitThen, let now = record.costPerUnitNow, then > 0 {
                    let pct = ((now - then) / then) * 100
                    let denom = max(then, now)
                    GeometryReader { geo in
                        VStack(alignment: .leading, spacing: 8) {
                            costBarRow(label: "Then", value: then.formattedCostPerUnit(),
                                       fraction: then / denom, width: geo.size.width,
                                       fill: Color(.systemFill))
                            costBarRow(label: "Now",  value: now.formattedCostPerUnit(),
                                       fraction: now / denom, width: geo.size.width,
                                       fill: Color.shrunkRed)
                        }
                    }
                    .frame(height: 64)

                    Text("\(pct.formattedPercentChange(decimals: 1)) more per ounce")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(pct > 0 ? Color.shrunkRedDark : Color.verdictGoodDeep)
                } else if let now = record.costPerUnitNow {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(now.formattedCostPerUnit())
                            .font(.title.bold())
                            .monospacedDigit()
                        Text("per oz")
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

    private func costBarRow(label: String, value: String, fraction: Double, width: CGFloat, fill: Color) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.tertiarySystemFill))
                    .frame(height: 22)
                Capsule()
                    .fill(fill)
                    .frame(width: max(8, width * 0.55 * CGFloat(fraction)), height: 22)
            }
            Text(value)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
        }
    }

    // MARK: - CTAs

    /// Spec §2's action column. The single-snapshot and no-size states lead
    /// with the action that moves *them* forward — watching, or the label photo
    /// that makes watching possible — rather than the alternatives button the
    /// shrink screen leads with.
    private func ctaSection(product: ShrunkProduct, record: ShrinkRecord) -> some View {
        let outcome = ResultViewModel.watchOutcome(
            record: record, isPro: storeKit.isProUser, isAlreadyWatched: isWatched
        )
        return VStack(spacing: 8) {
            if outcome == .needsLabel {
                // "We don't know this size yet": the label photo is the only
                // thing that unblocks this product, so it is the primary CTA.
                // Routed through `watchButton` like every other outcome, so
                // there is exactly one path from outcome to action.
                watchButton(outcome: outcome, product: product, record: record, variant: .primary)
                ShrunkButton("See better-value alternatives", icon: "arrow.right", variant: .ghost) {
                    showAlternatives = true
                }
            } else if record.verdict == .insufficientData {
                watchButton(outcome: outcome, product: product, record: record,
                            watchTitle: "Watch — we'll alert you if it shrinks", variant: .primary)
                ShrunkButton("See better-value alternatives", icon: "arrow.right", variant: .ghost) {
                    showAlternatives = true
                }
                ShrunkButton("Snap the label to confirm", icon: "camera", variant: .ghost) {
                    showLabelCapture = true
                }
            } else if record.verdict == .unchanged || record.verdict == .grew {
                // §2's "Unchanged / grew" row: there is no shrink to escape,
                // so the useful action is establishing the baseline — Watch is
                // primary here, alternatives and Share secondary.
                watchButton(outcome: outcome, product: product, record: record, variant:.primary)
                ShrunkButton("See better-value alternatives", icon: "arrow.right", variant: .ghost) {
                    showAlternatives = true
                }
            } else {
                ShrunkButton("See better-value alternatives", icon: "arrow.right") {
                    showAlternatives = true
                }
                watchButton(outcome: outcome, product: product, record: record, variant:.ghost)
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
                toastMessage = "Watching \(product.name) — we'll alert you if it shrinks or its price per oz jumps"
            }
            successHaptic += 1
        } catch {
            toastIsError = true
            withAnimation {
                toastMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Couldn't add this to your watchlist."
            }
            errorHaptic += 1
        }
    }

    // MARK: - Loading / not-found / error

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Looking up the shrink record…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private func notFoundView(barcode: String) -> some View {
        ContentUnavailableView {
            Label("Not in our database yet — snap the label to add it", systemImage: "camera.viewfinder")
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

            Button("Close") { dismiss() }
                .buttonStyle(.borderless)
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

    private func bannerSubline(for record: ShrinkRecord) -> String? {
        switch record.verdict {
        case .significantShrink, .moderateShrink, .minorShrink:
            guard let prev = record.previousSize, let curr = record.currentSize else { return nil }
            let diff = abs(prev.quantity - curr.quantity)
            return "They took \(Self.compact(diff)) \(curr.unit)"
        case .unchanged:
            // §2: "Same size since 2021" — the year of the *earliest*
            // observation, which is how far back we can actually vouch for it,
            // not the year of the latest one.
            guard let since = record.product.sizeHistory.map(\.date).min() else { return "Held its size" }
            return "Same size since \(since.formatted(.dateTime.year()))"
        case .grew:
            return "Grew \(record.shrinkPercent.formattedPercent(decimals: 0))"
        case .insufficientData:
            // Spec §2 — the single-snapshot screen is a first-class result,
            // not a degraded shrink screen, and says what it actually knows.
            return record.currentSize == nil ? "We don't know this size yet" : "No shrink on record"
        }
    }

    /// "32 fl oz, first seen Feb 2018" — or "28 fl oz at Kroger today" when the
    /// size was adopted from the live store row (spec §2, rule 5). Only the
    /// single-snapshot state needs it; the shrink states already draw a
    /// Then→Now row.
    private func sizeFactLine(for record: ShrinkRecord) -> String? {
        guard record.verdict == .insufficientData, let size = record.currentSize else { return nil }
        let quantity = size.quantity.formattedQuantity(unit: size.unit)
        if vm.adoptedLiveSize {
            let store = storeName.isEmpty ? "Kroger" : storeName
            return "\(quantity) at \(store) today"
        }
        return "\(quantity), first seen \(size.date.formatted(.dateTime.month(.abbreviated).year()))"
    }

    /// The cheapest store alternative that actually beats what the scanned
    /// product costs per ounce. Curated rows carry no `costPerUnit`, so they
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
                        Label("Cheapest per oz at your store", systemImage: "arrow.down.circle.fill")
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
        case .insufficientData: return .secondary
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
