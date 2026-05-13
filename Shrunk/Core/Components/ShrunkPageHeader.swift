import SwiftUI

/// Custom page header used at the top of each tab's scroll content. Replaces
/// NavigationStack's large title — gives us full design control over weight,
/// tracking, color, and adjacent elements (filters, badges).
struct ShrunkPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let trailing: () -> Trailing

    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 32, weight: .heavy, design: .default))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.smoke)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, ShrunkTheme.Spacing.lg)
        .padding(.top, ShrunkTheme.Spacing.sm)
        .padding(.bottom, ShrunkTheme.Spacing.sm)
    }
}
