import Foundation

@MainActor
final class BrowseViewModel: ObservableObject {
    enum BrowseCategory: String, CaseIterable, Identifiable {
        case snacks       = "Snacks"
        case beverages    = "Drinks"
        case dairy        = "Dairy"
        case cleaning     = "Cleaning"
        case personalCare = "Personal"
        case paper        = "Paper"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .snacks:       return "popcorn.fill"
            case .beverages:    return "cup.and.saucer.fill"
            case .dairy:        return "drop.fill"
            case .cleaning:     return "sparkles"
            case .personalCare: return "drop.degreesign"
            case .paper:        return "rectangle.stack.fill"
            }
        }

        var slug: String {
            switch self {
            case .snacks:       return "snacks"
            case .beverages:    return "beverages"
            case .dairy:        return "dairies"
            case .cleaning:     return "cleaning-products"
            case .personalCare: return "cosmetics"
            case .paper:        return "paper-products"
            }
        }

        /// Strings used in `ShrunkProduct.category` that should map to this tile.
        /// Trending feed entries use a loose mix ("Personal care", "Paper products",
        /// "Sugar", "Condiments", etc.) — keep them all here so filtering catches
        /// every variant that comes back from the feed.
        var matchesProductCategories: [String] {
            switch self {
            case .snacks:       return ["Snacks", "snacks"]
            case .beverages:    return ["Beverages", "beverages", "Drinks"]
            case .dairy:        return ["Dairy", "Dairies"]
            case .cleaning:     return ["Cleaning", "Cleaning products"]
            case .personalCare: return ["Personal care", "Cosmetics", "Personal", "Condiments"]
            case .paper:        return ["Paper products", "Paper"]
            }
        }
    }

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    @Published var trending: [ShrinkRecord] = []
    @Published var hallOfShame: [ShrinkRecord] = []
    @Published var categories: [BrowseCategory] = BrowseCategory.allCases
    @Published var loadState: LoadState = .idle
    @Published private(set) var lastUpdated: Date?

    let detector = ShrinkDetector()
    private let feed: TrendingFeedService

    init(feed: TrendingFeedService = .shared) {
        self.feed = feed
    }

    /// Triggers a fetch. Browse will show a loading state on first load and
    /// a "stale + refreshing" affordance on subsequent loads.
    func bootstrap() {
        guard loadState != .loading else { return }
        if !trending.isEmpty {
            // We already have data — refresh silently in the background.
            Task { await refreshSilently() }
            return
        }
        Task { await load(initial: true) }
    }

    /// Explicit pull-to-refresh from the Browse view.
    func refresh() async {
        await load(initial: false, forceRemote: true)
    }

    /// Records that map to a given Browse tile. Used by the category detail screen.
    func records(in category: BrowseCategory) -> [ShrinkRecord] {
        let matches = Set(category.matchesProductCategories)
        return hallOfShame
            .filter { matches.contains($0.product.category) }
            .sorted { abs($0.shrinkPercent) > abs($1.shrinkPercent) }
    }

    // MARK: - Loading

    private func load(initial: Bool, forceRemote: Bool = false) async {
        if initial { loadState = .loading }

        let feedData: TrendingFeed
        if forceRemote {
            if let remote = await feed.fetchRemote() {
                feedData = remote
            } else {
                feedData = await feed.fetch()
            }
        } else {
            feedData = await feed.fetch()
        }

        applyFeed(feedData)

        if feedData.trending.isEmpty {
            loadState = .error("Couldn't load shrinkflation cases. Pull to retry.")
        } else {
            loadState = .loaded
            lastUpdated = feedData.updated
        }
    }

    private func refreshSilently() async {
        guard let remote = await feed.fetchRemote() else { return }
        applyFeed(remote)
        lastUpdated = remote.updated
    }

    private func applyFeed(_ feed: TrendingFeed) {
        let analyzed = feed.trending
            .map { $0.toProduct() }
            .map { detector.analyze(product: $0) }
        let shrunk = analyzed.filter { $0.verdict.isShrink }
        trending = Array(shrunk.prefix(6))
        hallOfShame = shrunk.sorted { abs($0.shrinkPercent) > abs($1.shrinkPercent) }
    }
}
