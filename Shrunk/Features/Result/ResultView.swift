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
    @State private var watchedConfirmation: String?

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
        }
        .task(id: barcode) {
            if let prebake { vm.prebake(product: prebake.product, record: prebake.record) }
            await vm.load(barcode: barcode)
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
                costPerOzSection(record: record)
                if product.sizeHistory.count >= 2 {
                    ShrinkHistoryChart(history: product.sizeHistory)
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
            AlternativesView(product: product, record: record, alternatives: vm.alternatives)
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

    // MARK: - Cost-per-oz

    @ViewBuilder
    private func costPerOzSection(record: ShrinkRecord) -> some View {
        if record.costPerUnitNow == nil { EmptyView() } else {
            VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.md) {
                Text("REAL COST PER OUNCE").shrunkSectionLabel()

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

    private func ctaSection(product: ShrunkProduct, record: ShrinkRecord) -> some View {
        VStack(spacing: ShrunkTheme.Spacing.sm) {
            ShrunkButton("See better-value alternatives", icon: "arrow.right") {
                showAlternatives = true
            }
            ShrunkButton(
                watchedConfirmation == product.id ? "On your watchlist" : "Watch this product",
                icon: watchedConfirmation == product.id ? "bell.badge.fill" : "bell",
                variant: .ghost
            ) {
                if storeKit.isProUser {
                    addToWatchlist(product: product, record: record)
                } else {
                    showWatchPaywall = true
                }
            }
            .disabled(watchedConfirmation == product.id)
        }
    }

    private func addToWatchlist(product: ShrunkProduct, record: ShrinkRecord) {
        guard let currentSize = record.currentSize else { return }
        let service = WatchlistService(context: modelContext)
        do {
            try service.add(product: product, currentSize: currentSize)
            watchedConfirmation = product.id
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
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
                Image(systemName: "questionmark.app.dashed")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(Color.smoke)
            }
            Text("Not in our database yet")
                .font(.shrunkTitle)
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
                .padding(.top, ShrunkTheme.Spacing.sm)
            Text("Barcode \(barcode). Open Food Facts is community-maintained — adding it takes 30 seconds and helps every Shrunk user.")
                .font(.shrunkBody)
                .foregroundStyle(Color.smoke)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, ShrunkTheme.Spacing.lg)
            VStack(spacing: 10) {
                ShrunkButton("Add it on Open Food Facts", icon: "plus.circle.fill") {
                    let urlString = "https://world.openfoodfacts.org/cgi/product.pl?type=add&code=\(barcode)"
                    if let url = URL(string: urlString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Close") {
                    dismiss()
                }
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
            return "First snapshot — we'll catch any future change"
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
