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
        .task(id: barcode) {
            vm.isPro = storeKit.isProUser
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
            isWatched = ((try? WatchlistService(context: modelContext).fetch(barcode: barcode)) ?? nil) != nil
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
                .padding(.bottom, ShrunkTheme.Spacing.xl)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: toastMessage) {
                    try? await Task.sleep(nanoseconds: 2_800_000_000)
                    withAnimation { self.toastMessage = nil }
                }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(Color.ink)
                    .frame(width: 34, height: 34)
                    .background(Color.mist)
                    .clipShape(Circle())
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
            VStack(spacing: ShrunkTheme.Spacing.xl) {
                heroSection(product: product, record: record)
                comparisonRow(record: record)
                if product.needsConfirmation || vm.liveSizeMismatch {
                    confirmationCard
                        .padding(.horizontal, ShrunkTheme.Spacing.lg)
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
                    .padding(.horizontal, ShrunkTheme.Spacing.lg)
                }
                ctaSection(product: product, record: record)
                    .padding(.horizontal, ShrunkTheme.Spacing.lg)
                Spacer(minLength: ShrunkTheme.Spacing.xl)
            }
            .padding(.top, ShrunkTheme.Spacing.sm)
        }
        .background(Color.paper.ignoresSafeArea())
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
        VStack(spacing: ShrunkTheme.Spacing.lg) {
            ShrinkMeter(
                percentChange: record.shrinkPercent,
                verdict: record.verdict,
                size: .hero
            )
            .padding(.top, ShrunkTheme.Spacing.md)

            if product.imageURL != nil {
                ProductImage(url: product.imageURL, size: 88, cornerRadius: 14)
                    .padding(.top, -8)
            }

            VStack(spacing: 6) {
                Text(product.name)
                    .font(.shrunkLargeTitle)
                    .foregroundStyle(Color.ink)
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
                .font(.shrunkCallout)
                .foregroundStyle(Color.smoke)

                if let line = bannerSubline(for: record) {
                    Text(line)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(verdictTextColor(record.verdict))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(verdictTintColor(record.verdict))
                        .clipShape(Capsule())
                        .padding(.top, 4)
                }

                // Rule 1 — every loaded result states at least one concrete
                // fact. For the 98.5 % of products with a single snapshot that
                // fact is the size itself and when we first saw it.
                if let fact = sizeFactLine(for: record) {
                    Text(fact)
                        .font(.shrunkCallout)
                        .foregroundStyle(Color.smoke)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, ShrunkTheme.Spacing.lg)

            shareInline(product: product, record: record)
        }
    }

    private func shareInline(product: ShrunkProduct, record: ShrinkRecord) -> some View {
        HStack(spacing: ShrunkTheme.Spacing.sm) {
            Button {
                showShareCard = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .bold))
                    Text("Share verdict")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Color.shrunkRed)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.shrunkRedLight)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Then → Now comparison row

    @ViewBuilder
    private func comparisonRow(record: ShrinkRecord) -> some View {
        if let prev = record.previousSize, let curr = record.currentSize {
            HStack(spacing: ShrunkTheme.Spacing.sm) {
                quantityCell(label: "Then",
                             value: prev.quantity.formattedQuantity(unit: prev.unit),
                             date: prev.date,
                             accent: Color.smoke,
                             tint: Color.mist)
                Image(systemName: "arrow.right")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(verdictTextColor(record.verdict))
                quantityCell(label: "Now",
                             value: curr.quantity.formattedQuantity(unit: curr.unit),
                             date: curr.date,
                             accent: verdictTextColor(record.verdict),
                             tint: verdictTintColor(record.verdict))
            }
            .padding(.horizontal, ShrunkTheme.Spacing.lg)
        } else if let curr = record.currentSize {
            VStack(alignment: .leading, spacing: 4) {
                Text("CURRENT SIZE").shrunkSectionLabel()
                Text(curr.quantity.formattedQuantity(unit: curr.unit))
                    .font(.shrunkMonoBig)
                    .foregroundStyle(Color.ink)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .shrunkCard(radius: ShrunkTheme.Radius.lg, padding: ShrunkTheme.Spacing.md)
            .padding(.horizontal, ShrunkTheme.Spacing.lg)
        }
    }

    private func quantityCell(label: String, value: String, date: Date, accent: Color, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.8)
                .foregroundStyle(accent.opacity(0.85))
            Text(value)
                .font(.shrunkMonoDisplay)
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(date, format: .dateTime.year())
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.smoke)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ShrunkTheme.Spacing.md)
        .background(tint)
        .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.md, style: .continuous))
    }

    /// Shown when the live store size disagrees with our latest observation
    /// (spec §4 step 4). Phase 3 sets `needsConfirmation`; the flow is live now.
    private var confirmationCard: some View {
        VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.sm) {
            HStack(spacing: 8) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.verdictWarnDeep)
                Text("SIZE UNCONFIRMED").shrunkSectionLabel()
            }
            Text("The size we're showing might be out of date. A photo of the net-weight line settles it.")
                .font(.shrunkCallout)
                .foregroundStyle(Color.smoke)
                .fixedSize(horizontal: false, vertical: true)
            ShrunkButton("Confirm with a label photo", icon: "camera.fill", variant: .ghost) {
                showLabelCapture = true
            }
        }
        .shrunkCard(radius: ShrunkTheme.Radius.lg, padding: ShrunkTheme.Spacing.md)
    }

    // MARK: - Cost-per-oz

    @ViewBuilder
    private func costPerOzSection(record: ShrinkRecord) -> some View {
        if record.costPerUnitNow == nil { EmptyView() } else {
            VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.md) {
                // When `costPerUnitNow` came from `product.priceHistory`
                // (`price_snapshots` — Kroger-derived), this card must carry the
                // same attribution `LivePricePanel` does (spec §9, Phase 3 review
                // I6). It must NOT show attribution when the price fell back to
                // `product.currentPrice` with no snapshot history — e.g. curated
                // Browse cards, whose price is not Kroger data (I6 regression fix).
                HStack {
                    Text("REAL COST PER OUNCE").shrunkSectionLabel()
                    Spacer()
                    if record.priceIsFromStoreSnapshot {
                        Text(LivePrice.attribution)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.smoke)
                    }
                }

                if let then = record.costPerUnitThen, let now = record.costPerUnitNow, then > 0 {
                    let pct = ((now - then) / then) * 100
                    let denom = max(then, now)
                    GeometryReader { geo in
                        VStack(alignment: .leading, spacing: 8) {
                            costBarRow(label: "Then", value: then.formattedCostPerUnit(),
                                       fraction: then / denom, width: geo.size.width,
                                       fill: Color.smoke.opacity(0.45))
                            costBarRow(label: "Now",  value: now.formattedCostPerUnit(),
                                       fraction: now / denom, width: geo.size.width,
                                       fill: Color.shrunkRed)
                        }
                    }
                    .frame(height: 64)

                    Text("\(pct.formattedPercentChange(decimals: 1)) more per ounce")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(pct > 0 ? Color.shrunkRedDark : Color.verdictGoodDeep)
                } else if let now = record.costPerUnitNow {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(now.formattedCostPerUnit())
                            .font(.shrunkMonoBig)
                            .foregroundStyle(Color.ink)
                        Text("per oz")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.smoke)
                    }
                    Text("We don't have a historical price to compare against — yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.smoke)
                }
            }
            .shrunkCard(radius: ShrunkTheme.Radius.lg, padding: ShrunkTheme.Spacing.md)
            .padding(.horizontal, ShrunkTheme.Spacing.lg)
        }
    }

    private func costBarRow(label: String, value: String, fraction: Double, width: CGFloat, fill: Color) -> some View {
        HStack(spacing: ShrunkTheme.Spacing.sm) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(Color.smoke)
                .frame(width: 38, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.mist)
                    .frame(height: 22)
                Capsule()
                    .fill(fill)
                    .frame(width: max(8, width * 0.55 * CGFloat(fraction)), height: 22)
            }
            Text(value)
                .font(.shrunkMonoSmall)
                .foregroundStyle(Color.ink)
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
        return VStack(spacing: ShrunkTheme.Spacing.sm) {
            if outcome == .needsLabel {
                // "We don't know this size yet": the label photo is the only
                // thing that unblocks this product, so it is the primary CTA.
                ShrunkButton("Snap the label to start tracking", icon: "camera.fill") {
                    showLabelCapture = true
                }
                ShrunkButton("See better-value alternatives", icon: "arrow.right", variant: .ghost) {
                    showAlternatives = true
                }
            } else if record.verdict == .insufficientData {
                watchButton(outcome: outcome, product: product, record: record,
                            title: "Watch — we'll alert you if it shrinks", variant: .primary)
                ShrunkButton("See better-value alternatives", icon: "arrow.right", variant: .ghost) {
                    showAlternatives = true
                }
                ShrunkButton("Snap the label to confirm", icon: "camera", variant: .ghost) {
                    showLabelCapture = true
                }
            } else {
                ShrunkButton("See better-value alternatives", icon: "arrow.right") {
                    showAlternatives = true
                }
                watchButton(outcome: outcome, product: product, record: record,
                            title: "Watch this product", variant: .ghost)
            }
        }
    }

    private func watchButton(
        outcome: ResultViewModel.WatchOutcome,
        product: ShrunkProduct,
        record: ShrinkRecord,
        title: String,
        variant: ShrunkButtonVariant
    ) -> some View {
        ShrunkButton(
            outcome == .alreadyWatched ? "On your watchlist" : title,
            icon: outcome == .alreadyWatched ? "bell.badge.fill" : "bell",
            variant: variant
        ) {
            handleWatch(outcome: outcome, product: product, record: record)
        }
        .disabled(outcome == .alreadyWatched)
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
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            toastIsError = true
            withAnimation {
                toastMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Couldn't add this to your watchlist."
            }
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    // MARK: - Loading / not-found / error

    private var loadingView: some View {
        VStack(spacing: ShrunkTheme.Spacing.md) {
            ProgressView()
                .controlSize(.large)
                .tint(Color.shrunkRed)
            Text("Looking up the shrink record…")
                .font(.shrunkBody)
                .foregroundStyle(Color.smoke)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.paper)
    }

    private func notFoundView(barcode: String) -> some View {
        VStack(spacing: ShrunkTheme.Spacing.md) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.mist)
                    .frame(width: 96, height: 96)
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(Color.smoke)
            }
            Text("Not in our database yet — snap the label to add it")
                .font(.shrunkTitle)
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
                .padding(.top, ShrunkTheme.Spacing.sm)
                .padding(.horizontal, ShrunkTheme.Spacing.lg)
            Text("Barcode \(barcode). One photo of the net-weight line adds it for every Shrunk user.")
                .font(.shrunkBody)
                .foregroundStyle(Color.smoke)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, ShrunkTheme.Spacing.lg)
            VStack(spacing: 10) {
                ShrunkButton("Snap the label", icon: "camera.fill") {
                    showLabelCapture = true
                }
                Button("Close") { dismiss() }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.smoke)
            }
            .padding(.horizontal, ShrunkTheme.Spacing.lg)
            .padding(.top, ShrunkTheme.Spacing.md)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.paper)
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
        .background(Color.paper)
    }

    // MARK: - Helpers

    private func bannerSubline(for record: ShrinkRecord) -> String? {
        switch record.verdict {
        case .significantShrink, .moderateShrink, .minorShrink:
            guard let prev = record.previousSize, let curr = record.currentSize else { return nil }
            let diff = abs(prev.quantity - curr.quantity)
            return "They took \(Self.compact(diff)) \(curr.unit)"
        case .unchanged:
            return "Held its size"
        case .grew:
            return "Grew — rare"
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

    @ViewBuilder
    private func cheapestAlternativeCallout(record: ShrinkRecord) -> some View {
        if let best = cheapestAlternative(for: record) {
            Button {
                showAlternatives = true
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.verdictGoodDeep)
                        Text("CHEAPEST PER OZ AT YOUR STORE").shrunkSectionLabel()
                        Spacer(minLength: 0)
                    }
                    Text(best.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    Text(best.verdict)
                        .font(.shrunkCallout)
                        .foregroundStyle(Color.smoke)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .shrunkCard(radius: ShrunkTheme.Radius.lg, padding: ShrunkTheme.Spacing.md)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, ShrunkTheme.Spacing.lg)
        }
    }

    private func verdictTextColor(_ v: ShrinkRecord.ShrinkVerdict) -> Color {
        switch v {
        case .significantShrink: return .shrunkRedDark
        case .moderateShrink, .minorShrink: return .verdictWarnDeep
        case .unchanged, .grew: return .verdictGoodDeep
        case .insufficientData: return .smoke
        }
    }

    private func verdictTintColor(_ v: ShrinkRecord.ShrinkVerdict) -> Color {
        switch v {
        case .significantShrink: return .shrunkRedLight
        case .moderateShrink, .minorShrink: return .verdictWarnTint
        case .unchanged, .grew: return .verdictGoodTint
        case .insufficientData: return .mist
        }
    }

    private static func compact(_ value: Double) -> String {
        if value == value.rounded() {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}
