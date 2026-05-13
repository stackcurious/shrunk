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

    func refresh() async -> [(WatchedProduct, ShrinkRecord)] {
        isRefreshing = true
        let results = await service.refreshAll()
        isRefreshing = false
        return results
    }
}
