import SwiftUI

struct ProBadge: View {
    enum Style {
        case pill           // "PRO" pill, used inline next to a label
        case lock           // small lock glyph, used overlaying gated UI
        case ribbon         // larger banner used in paywall hero
    }

    let style: Style

    init(style: Style = .pill) {
        self.style = style
    }

    var body: some View {
        switch style {
        case .pill:
            HStack(spacing: 3) {
                Image(systemName: "lock.fill")
                    .font(.caption2.weight(.semibold))
                Text("PRO")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.shrunkRed)
            .clipShape(Capsule())

        case .lock:
            Image(systemName: "lock.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(6)
                .background(Color.shrunkRed)
                .clipShape(Circle())

        case .ribbon:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.subheadline.weight(.semibold))
                Text("Shrunk Pro")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.shrunkRed, in: Capsule())
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        HStack { Text("Watchlist"); ProBadge(style: .pill) }
        ProBadge(style: .lock)
        ProBadge(style: .ribbon)
    }
    .padding()
}
