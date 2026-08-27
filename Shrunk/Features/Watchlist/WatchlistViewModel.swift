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

    func toggleAlert(for watched: WatchedProduct) {
        do {
            try service.setAlertEnabled(!watched.alertEnabled, for: watched)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func remove(_ watched: WatchedProduct) {
        do {
            try service.remove(watched)
        } catch {
            errorMessage = error.localizedDescription
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
