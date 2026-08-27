import SwiftUI

/// Thin wrapper over `ContentUnavailableView` (spec §3). Kept as a named type
/// because several screens pass an optional action, which the system view
/// expresses as an `actions` builder.
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        icon: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }
}

#Preview {
    EmptyStateView(
        icon: "bell.badge",
        title: "Nothing on your watchlist yet",
        message: "Watch products from their result screen — we'll alert you if they shrink.",
        actionTitle: "Scan a product"
    ) { }
    .tint(.shrunkRed)
}
