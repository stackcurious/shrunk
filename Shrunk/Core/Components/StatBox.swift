import SwiftUI

enum StatBoxTone {
    case neutral    // default white card with hairline border
    case alert      // light red wash — used when this stat is the bad news
    case good       // light green wash — used when this stat is the good news
    case muted      // gray wash — used for missing data
}

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
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(labelColor)

            Text(value)
                .font(.shrunkMonoNumber)
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let subline {
                Text(subline)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.smoke)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ShrunkTheme.Spacing.md)
        .padding(.vertical, 14)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ShrunkTheme.Radius.md, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private var backgroundColor: Color {
        switch tone {
        case .neutral: return .white
        case .alert:   return .shrunkRedLight
        case .good:    return Color(hex: "E8F5EE")
        case .muted:   return .mist
        }
    }

    private var borderColor: Color {
        switch tone {
        case .neutral: return .border
        case .alert:   return .shrunkRed.opacity(0.25)
        case .good:    return .verdictGood.opacity(0.25)
        case .muted:   return .border
        }
    }

    private var labelColor: Color {
        switch tone {
        case .alert: return .shrunkRedDark
        case .good:  return .verdictGood
        default:     return .smoke
        }
    }

    private var valueColor: Color {
        switch tone {
        case .alert: return .shrunkRedDark
        case .good:  return .verdictGood
        default:     return .ink
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
    .background(Color.mist)
}
