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
                    .font(.system(size: 9, weight: .bold))
                Text("PRO")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(0.6)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.shrunkRed)
            .clipShape(Capsule())

        case .lock:
            Image(systemName: "lock.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .padding(6)
                .background(Color.shrunkRed)
                .clipShape(Circle())

        case .ribbon:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 14, weight: .bold))
                Text("Shrunk Pro")
                    .font(.system(size: 14, weight: .bold))
                    .tracking(0.4)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                LinearGradient(
                    colors: [Color.shrunkRed, Color.shrunkRedDark],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(Capsule())
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
