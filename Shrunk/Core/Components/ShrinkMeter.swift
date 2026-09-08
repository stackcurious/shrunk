import SwiftUI

/// Signature visual: concentric ring + monospaced hero percentage. Used as the
/// hero on the Result screen, on Browse trending cards, on the Paywall, and
/// as a thumbnail on alternatives. This is what makes Shrunk recognizable.
struct ShrinkMeter: View {
    enum Size {
        case hero       // ~220pt, used on Result + Paywall
        case compact    // ~96pt, used on Browse + Watchlist hero strips
        case mini       // ~56pt, used in lists
    }

    let percentChange: Double
    let verdict: ShrinkRecord.ShrinkVerdict
    let size: Size

    @State private var animatedFill: CGFloat = 0

    init(percentChange: Double, verdict: ShrinkRecord.ShrinkVerdict, size: Size = .hero) {
        self.percentChange = percentChange
        self.verdict = verdict
        self.size = size
    }

    var body: some View {
        ZStack {
            // Outer track ring
            Circle()
                .stroke(Color(.systemFill), lineWidth: trackWidth)

            // Filled arc — represents the magnitude of the change
            Circle()
                .trim(from: 0, to: animatedFill)
                .stroke(
                    accentGradient,
                    style: StrokeStyle(lineWidth: trackWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))    // start at 12 o'clock
                .animation(.spring(response: 0.85, dampingFraction: 0.85), value: animatedFill)

            // Center disc — gives the meter physical depth
            Circle()
                .fill(Color(.secondarySystemGroupedBackground))
                .padding(trackWidth + 4)

            // Faint inner accent ring — the meter's "heartbeat"
            Circle()
                .stroke(accentColor.opacity(0.12), lineWidth: innerRingWidth)
                .padding(trackWidth + 4)

            // Center label stack
            VStack(spacing: centerSpacing) {
                Text(headline)
                    .font(headlineFont)
                    .monospacedDigit()
                    .foregroundStyle(accentColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let sub = subtitle {
                    Text(sub)
                        .font(subtitleFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, dimension * 0.12)
            // The ring is a fixed-diameter graphic, so its two labels can't
            // grow past `.accessibility1` without spilling out of it — at AX5
            // the compact meter's subtitle truncated to "S…" (review B3).
            // Everything the meter says is also in the accessibility label
            // below, which is not capped.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
        .frame(width: dimension, height: dimension)
        // Two loose `Text`s with no label for the ring itself; now one element
        // that says what it means (review S16).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .onAppear {
            // Tiny delay then animate the ring fill — gives the screen entrance a beat.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                animatedFill = targetFillFraction
            }
        }
        .onChange(of: percentChange) { _, _ in
            animatedFill = targetFillFraction
        }
    }

    // MARK: - Geometry

    private var dimension: CGFloat {
        switch size {
        case .hero:    return 220
        case .compact: return 96
        case .mini:    return 56
        }
    }

    private var trackWidth: CGFloat {
        switch size {
        case .hero:    return 12
        case .compact: return 7
        case .mini:    return 5
        }
    }

    private var innerRingWidth: CGFloat {
        switch size {
        case .hero:    return 1.5
        case .compact: return 1
        case .mini:    return 0.75
        }
    }

    private var centerSpacing: CGFloat {
        switch size {
        case .hero:    return 4
        case .compact: return 1
        case .mini:    return 0
        }
    }

    // MARK: - Style mapping

    /// The arc *is* the percentage: a full circle is 100 %, so a 12 % shrink
    /// draws a 12 % arc. It used to run on a 25 % (shrink) / 30 % (grew) full
    /// scale, which drew a half-full ring around the numeral "12%" — a gauge
    /// contradicting the number inside it (review N1).
    private var targetFillFraction: CGFloat {
        switch verdict {
        case .insufficientData, .unchanged:
            return 0.04   // tiny stub — shows the ring is alive but not registering a delta
        case .grew, .significantShrink, .moderateShrink, .minorShrink:
            return min(1.0, max(0.04, CGFloat(abs(percentChange) / 100)))
        }
    }

    private var accentColor: Color {
        switch verdict {
        case .significantShrink: return .verdictBad
        case .moderateShrink:    return .verdictWarn
        case .minorShrink:       return .verdictWarn
        case .unchanged:         return .verdictGood
        case .grew:              return .verdictGood
        case .insufficientData:  return .secondary
        }
    }

    private var accentGradient: AngularGradient {
        AngularGradient(
            gradient: Gradient(colors: [accentColor.opacity(0.65), accentColor]),
            center: .center,
            startAngle: .degrees(-90),
            endAngle: .degrees(270)
        )
    }

    private var headline: String {
        switch verdict {
        case .significantShrink, .moderateShrink, .minorShrink:
            return percentString(abs(percentChange), withSign: false)
        case .unchanged:
            return "0"
        case .grew:
            return "+" + percentString(abs(percentChange), withSign: false)
        case .insufficientData:
            return "1"
        }
    }

    private func percentString(_ value: Double, withSign: Bool) -> String {
        if size == .mini {
            return "\(Int(value.rounded()))%"
        }
        if value < 10 {
            return String(format: "%.1f%%", value)
        }
        return String(format: "%.0f%%", value)
    }

    private var subtitle: String? {
        guard size != .mini else { return nil }
        switch verdict {
        case .significantShrink: return "Smaller"
        case .moderateShrink:    return "Smaller"
        case .minorShrink:       return "Smaller"
        case .unchanged:         return "Held"
        case .grew:              return "Grew"
        case .insufficientData:  return "Baseline"
        }
    }

    /// The ring is a fixed-diameter circle, so the hero numeral keeps a fixed
    /// point size (the same call the savings hero makes) rather than scaling
    /// out of its own frame. `compact` and `mini` sit inside list rows and use
    /// ordinary text styles.
    private var headlineFont: Font {
        switch size {
        case .hero:    return Font.system(size: 56, weight: .bold)
        case .compact: return .title3.bold()
        case .mini:    return .subheadline.bold()
        }
    }

    /// What the ring, the numeral and the caption add up to, in one sentence.
    private var accessibilityDescription: String {
        let magnitude = String(format: "%.1f", abs(percentChange))
        switch verdict {
        case .significantShrink, .moderateShrink, .minorShrink:
            return "Package size decreased \(magnitude) percent"
        case .grew:
            return "Grew \(magnitude) percent"
        case .unchanged:
            return "Held its size"
        case .insufficientData:
            return "One package size on record — baseline established"
        }
    }

    private var subtitleFont: Font {
        switch size {
        case .hero:    return .footnote.weight(.semibold)
        case .compact: return .caption2.weight(.semibold)
        case .mini:    return .caption2.weight(.semibold)
        }
    }
}

#Preview {
    VStack(spacing: 32) {
        HStack(spacing: 16) {
            ShrinkMeter(percentChange: -12.5, verdict: .significantShrink, size: .compact)
            ShrinkMeter(percentChange: -7.0,  verdict: .moderateShrink,    size: .compact)
            ShrinkMeter(percentChange: -2.5,  verdict: .minorShrink,       size: .compact)
        }
        HStack(spacing: 16) {
            ShrinkMeter(percentChange: 0,     verdict: .unchanged,         size: .compact)
            ShrinkMeter(percentChange: 6.4,   verdict: .grew,              size: .compact)
            ShrinkMeter(percentChange: 0,     verdict: .insufficientData,  size: .compact)
        }
        ShrinkMeter(percentChange: -12.5, verdict: .significantShrink, size: .hero)
    }
    .padding(32)
    .background(Color(.systemGroupedBackground))
}
