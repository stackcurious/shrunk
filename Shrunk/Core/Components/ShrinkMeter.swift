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
                .stroke(Color.borderSoft, lineWidth: trackWidth)

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
                .fill(Color.surface)
                .padding(trackWidth + 4)
                .shrunkElevation(ShrunkTheme.Elevation.whisper)

            // Faint inner accent ring — the meter's "heartbeat"
            Circle()
                .stroke(accentColor.opacity(0.12), lineWidth: innerRingWidth)
                .padding(trackWidth + 4)

            // Center label stack
            VStack(spacing: centerSpacing) {
                Text(headline)
                    .font(headlineFont)
                    .foregroundStyle(accentColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let sub = subtitle {
                    Text(sub.uppercased())
                        .font(subtitleFont)
                        .tracking(subtitleTracking)
                        .foregroundStyle(Color.smoke)
                }
            }
            .padding(.horizontal, dimension * 0.12)
        }
        .frame(width: dimension, height: dimension)
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

    private var targetFillFraction: CGFloat {
        switch verdict {
        case .insufficientData, .unchanged:
            return 0.04   // tiny stub — shows the ring is alive but not registering a delta
        case .grew:
            return min(1.0, CGFloat(abs(percentChange) / 30))
        case .significantShrink, .moderateShrink, .minorShrink:
            return min(1.0, CGFloat(abs(percentChange) / 25))
        }
    }

    private var accentColor: Color {
        switch verdict {
        case .significantShrink: return .verdictBad
        case .moderateShrink:    return .verdictWarn
        case .minorShrink:       return .verdictWarn
        case .unchanged:         return .verdictGood
        case .grew:              return .verdictGood
        case .insufficientData:  return .smoke
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
            return "?"
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
        case .significantShrink: return "Shrunk"
        case .moderateShrink:    return "Shrunk"
        case .minorShrink:       return "Shrunk"
        case .unchanged:         return "Held"
        case .grew:              return "Grew"
        case .insufficientData:  return "First scan"
        }
    }

    private var headlineFont: Font {
        switch size {
        case .hero:    return Font.system(size: 56, weight: .heavy, design: .rounded)
        case .compact: return Font.system(size: 22, weight: .heavy, design: .rounded)
        case .mini:    return Font.system(size: 14, weight: .heavy, design: .rounded)
        }
    }

    private var subtitleFont: Font {
        switch size {
        case .hero:    return Font.system(size: 13, weight: .heavy)
        case .compact: return Font.system(size: 9,  weight: .heavy)
        case .mini:    return Font.system(size: 8,  weight: .heavy)
        }
    }

    private var subtitleTracking: CGFloat {
        switch size {
        case .hero:    return 1.2
        case .compact: return 0.8
        case .mini:    return 0.6
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
    .background(Color.paper)
}
