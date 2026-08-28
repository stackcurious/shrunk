import Foundation
import SwiftData
import Observation

@Observable
@MainActor
final class WatchlistViewModel {
    var presentedBarcode: String?
    var errorMessage: String?
    var isRefreshing: Bool = false

    private let service: WatchlistService

    init(service: WatchlistService) {
        self.service = service
    }

    /// Both mutators report whether they actually did the thing. `errorMessage`
    /// used to be written and never read anywhere in the tree, and the view
    /// toasted "Removed from watchlist" whether or not the delete threw
    /// (spec rule 4, review S11).
    @discardableResult
    func toggleAlert(for watched: WatchedProduct) -> Bool {
        do {
            try service.setAlertEnabled(!watched.alertEnabled, for: watched)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func remove(_ watched: WatchedProduct) -> Bool {
        do {
            try service.remove(watched)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Syncs the list to the Worker, then runs the live-size check. Returns the
    /// number of products whose store size disagrees with what we last recorded.
    func refresh() async -> Int {
        isRefreshing = true
        await service.syncToBackend()
        let mismatches = await service.liveSizeCheck()
        isRefreshing = false
        return mismatches.count
    }
}
