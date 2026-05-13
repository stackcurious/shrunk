import Foundation
import SwiftData
import Observation

@Observable
@MainActor
final class AlertsViewModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case new = "New"
        case confirmed = "Confirmed"
        case watching = "Watching"
        var id: String { rawValue }
    }

    var selectedFilter: Filter = .all
    var presentedBarcode: String?

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func filtered(_ alerts: [ShrinkAlert]) -> [ShrinkAlert] {
        switch selectedFilter {
        case .all:       return alerts
        case .new:       return alerts.filter { !$0.isRead }
        case .confirmed: return alerts.filter { $0.kind == .newShrink }
        case .watching:  return alerts.filter { $0.kind == .stable || $0.kind == .unconfirmed }
        }
    }

    func markRead(_ alert: ShrinkAlert) {
        guard !alert.isRead else { return }
        alert.isRead = true
        try? context.save()
    }

    /// Aggregates the per-unit cost delta of confirmed shrinks into a rough
    /// "money you avoided" headline figure for the savings strip.
    func protectedThisMonth(from alerts: [ShrinkAlert]) -> Double {
        let cal = Calendar.current
        return alerts
            .filter { $0.kind == .newShrink }
            .filter { cal.isDate($0.createdAt, equalTo: Date(), toGranularity: .month) }
            .compactMap { $0.costDeltaPerUnit }
            .reduce(0, +)
    }
}
