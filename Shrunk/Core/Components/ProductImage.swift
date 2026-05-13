import SwiftUI

/// Async-loaded product image with a brand-consistent placeholder. Falls back
/// to a category-glyph placeholder when no URL is provided or the image fails
/// to load. Always renders in a square frame to keep grid alignment.
struct ProductImage: View {
    let url: URL?
    var fallbackIcon: String = "shippingbox.fill"
    var size: CGFloat = 56
    var cornerRadius: CGFloat = 10

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        placeholder(loading: true)
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        placeholder(loading: false)
                    @unknown default:
                        placeholder(loading: false)
                    }
                }
            } else {
                placeholder(loading: false)
            }
        }
        .frame(width: size, height: size)
        .background(Color.mist)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.borderSoft, lineWidth: 0.5)
        )
    }

    private func placeholder(loading: Bool) -> some View {
        ZStack {
            Color.mist
            if loading {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.smoke)
            } else {
                Image(systemName: fallbackIcon)
                    .font(.system(size: size * 0.38, weight: .regular))
                    .foregroundStyle(Color.smokeSoft)
            }
        }
    }
}
