import SwiftUI

enum StatBoxTone {
    case neutral    // default grouped-cell surface
    case alert      // this stat is the bad news
    case good       // this stat is the good news
    case muted      // missing data
}

/// A single labelled figure, rendered as a `GroupBox`-style cell: system text
/// styles, `.monospacedDigit()` numerals, semantic background (spec §3).
struct StatBox: View {
    let label: String
    let value: String
    let subline: String?
    let tone: StatBoxTone

    init(label: String, value: String, subline: String? = nil, tone: StatBoxTone = .neutral) {
        self.label = label
        self.value = value
        self.subline = subline
        self.tone = tone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(labelColor)

            Text(value)
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let subline {
                Text(subline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var backgroundColor: Color {
        switch tone {
        case .neutral: return Color(.secondarySystemGroupedBackground)
        case .alert:   return .shrunkRedLight
        case .good:    return .verdictGoodTint
        case .muted:   return Color(.tertiarySystemFill)
        }
    }

    private var labelColor: Color {
        switch tone {
        case .alert: return .shrunkRedDark
        case .good:  return .verdictGoodDeep
        default:     return Color(.secondaryLabel)
        }
    }

    private var valueColor: Color {
        switch tone {
        case .alert: return .shrunkRedDark
        case .good:  return .verdictGoodDeep
        default:     return Color(.label)
        }
    }
}

#Preview {
    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
        StatBox(label: "Current size", value: "28 oz")
        StatBox(label: "Previous size", value: "32 oz", subline: "before 2022", tone: .alert)
        StatBox(label: "Price now", value: "$1.89", subline: "same as 2021", tone: .alert)
        StatBox(label: "Cost / oz", value: "6.8¢", subline: "+14.3% more", tone: .alert)
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}
