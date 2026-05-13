import SwiftUI

/// Bottom-anchored, pill-shaped, ink-colored toast. Used for transient feedback
/// after one-off actions (refresh, save, remove, etc.). Caller controls visibility
/// and dismissal timing — Toast is a pure presentation component.
struct Toast: View {
    let message: String
    var icon: String = "checkmark.circle.fill"
    var tint: Color = .verdictGood

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tint)
            Text(message)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.ink)
        .clipShape(Capsule())
        .shrunkElevation(ShrunkTheme.Elevation.float)
        .padding(.horizontal, ShrunkTheme.Spacing.lg)
    }
}
