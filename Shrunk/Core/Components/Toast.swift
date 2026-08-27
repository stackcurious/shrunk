import SwiftUI

/// Bottom-anchored transient feedback. Caller controls visibility and dismissal
/// timing — Toast is a pure presentation component. Styled on `.regularMaterial`
/// so it reads as a system overlay in either colour scheme (spec §3).
struct Toast: View {
    let message: String
    var icon: String = "checkmark.circle.fill"
    var tint: Color = .verdictGood

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color(.separator), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 20)
    }
}

#Preview {
    Toast(message: "Watching Bounty Select-A-Size")
}
