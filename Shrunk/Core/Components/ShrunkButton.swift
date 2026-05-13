import SwiftUI
import UIKit

enum ShrunkButtonVariant {
    case primary      // filled red — main CTA
    case secondary    // gray fill — companion action
    case ghost        // transparent with red border — tertiary
    case destructive  // dark red — irreversible action
}

struct ShrunkButton: View {
    let title: String
    let icon: String?
    let variant: ShrunkButtonVariant
    let isLoading: Bool
    let action: () -> Void

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
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(foreground)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ShrunkTheme.Radius.md, style: .continuous)
                    .stroke(borderColor, lineWidth: borderWidth)
            )
        }
        .buttonStyle(ShrunkButtonPressStyle())
        .disabled(isLoading)
        .accessibilityLabel(Text(title))
    }

    private var foreground: Color {
        switch variant {
        case .primary, .destructive: return .white
        case .secondary:             return .ink
        case .ghost:                 return .shrunkRed
        }
    }

    private var background: Color {
        switch variant {
        case .primary:     return .shrunkRed
        case .secondary:   return .mist
        case .ghost:       return .clear
        case .destructive: return .shrunkRedDark
        }
    }

    private var borderColor: Color {
        variant == .ghost ? Color.shrunkRed.opacity(0.35) : .clear
    }

    private var borderWidth: CGFloat {
        variant == .ghost ? 1.5 : 0
    }
}

private struct ShrunkButtonPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.72),
                       value: configuration.isPressed)
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
}
