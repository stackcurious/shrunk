import SwiftUI

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
        VStack(spacing: ShrunkTheme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(Color.mist)
                    .frame(width: 84, height: 84)
                Image(systemName: icon)
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(Color.smoke)
            }

            Text(title)
                .font(.shrunkTitle)
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)

            Text(message)
                .font(.shrunkBody)
                .foregroundStyle(Color.smoke)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, ShrunkTheme.Spacing.lg)

            if let actionTitle, let action {
                ShrunkButton(actionTitle, variant: .ghost, action: action)
                    .padding(.top, 8)
                    .padding(.horizontal, ShrunkTheme.Spacing.xl)
            }
        }
        .padding(.horizontal, ShrunkTheme.Spacing.lg)
        .padding(.vertical, ShrunkTheme.Spacing.xxl)
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    EmptyStateView(
        icon: "bell.badge",
        title: "Nothing on your watchlist yet",
        message: "Watch products from their result screen — we'll alert you if they shrink.",
        actionTitle: "Scan a product"
    ) { }
}
