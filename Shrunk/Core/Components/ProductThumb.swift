import SwiftUI

struct ProductThumb: View {
    let imageURL: URL?
    let category: String
    let size: CGFloat

    init(imageURL: URL?, category: String = "", size: CGFloat = 56) {
        self.imageURL = imageURL
        self.category = category
        self.size = size
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: ShrunkTheme.Radius.sm, style: .continuous)
                .fill(Color.mist)

            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .controlSize(.small)
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .padding(size * 0.08)
                    case .failure:
                        fallback
                    @unknown default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ShrunkTheme.Radius.sm, style: .continuous)
                .stroke(Color.border, lineWidth: 1)
        )
    }

    private var fallback: some View {
        Image(systemName: ProductThumb.icon(for: category))
            .font(.system(size: size * 0.42, weight: .regular))
            .foregroundStyle(Color.smoke)
    }

    static func icon(for category: String) -> String {
        let key = category.lowercased()
        if key.contains("beverage") || key.contains("drink") || key.contains("water") || key.contains("juice") || key.contains("soda") {
            return "cup.and.saucer.fill"
        }
        if key.contains("snack") || key.contains("chip") || key.contains("cracker") || key.contains("cookie") {
            return "popcorn.fill"
        }
        if key.contains("dairy") || key.contains("milk") || key.contains("cheese") || key.contains("yogurt") {
            return "drop.fill"
        }
        if key.contains("clean") || key.contains("detergent") || key.contains("soap") {
            return "sparkles"
        }
        if key.contains("paper") || key.contains("tissue") || key.contains("towel") {
            return "rectangle.stack.fill"
        }
        if key.contains("personal") || key.contains("hygiene") || key.contains("care") {
            return "drop.degreesign"
        }
        return "barcode"
    }
}

#Preview {
    HStack(spacing: 12) {
        ProductThumb(imageURL: nil, category: "Beverages")
        ProductThumb(imageURL: nil, category: "Snacks")
        ProductThumb(imageURL: nil, category: "Dairy")
        ProductThumb(imageURL: nil, category: "")
    }
    .padding()
}
