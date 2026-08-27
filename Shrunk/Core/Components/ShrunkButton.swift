import SwiftUI

/// Which of the system button styles this action gets. The names are the app's
/// old vocabulary, kept so call sites don't churn; the rendering underneath is
/// now `.borderedProminent` / `.bordered` / `.borderless` at
/// `.controlSize(.large)`, i.e. an ordinary iOS button.
enum ShrunkButtonVariant {
    case primary      // filled with the app tint — main CTA
    case secondary    // neutral bordered — companion action
    case ghost        // borderless — tertiary
    case destructive  // filled, destructive role
}

struct ShrunkButton: View {
    let title: String
    let icon: String?
    let variant: ShrunkButtonVariant
    let isLoading: Bool
    let action: () -> Void

    @State private var tapCount: Int = 0

    init(
        _ title: String,
        icon: String? = nil,
        variant: ShrunkButtonVariant = .primary,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.variant = variant
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        styled
            .controlSize(.large)
            .disabled(isLoading)
            // Replaces the UIImpactFeedbackGenerator the old custom style fired
            // by hand on every tap (spec §3, "Motion").
            .sensoryFeedback(.impact(weight: .light), trigger: tapCount)
            .accessibilityLabel(Text(title))
    }

    @ViewBuilder
    private var styled: some View {
        switch variant {
        case .primary:
            button.buttonStyle(.borderedProminent)
        case .destructive:
            button.buttonStyle(.borderedProminent)
        case .secondary:
            button.buttonStyle(.bordered).tint(.primary)
        case .ghost:
            button.buttonStyle(.borderless)
        }
    }

    private var button: some View {
        Button(role: variant == .destructive ? .destructive : nil) {
            tapCount += 1
            action()
        } label: {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else if let icon {
                    Image(systemName: icon)
                }
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        ShrunkButton("See better value alternatives", icon: "arrow.right") {}
        ShrunkButton("Watch this product", icon: "bell", variant: .secondary) {}
        ShrunkButton("Maybe later", variant: .ghost) {}
        ShrunkButton("Working", isLoading: true) {}
    }
    .padding()
    .tint(.shrunkRed)
}
