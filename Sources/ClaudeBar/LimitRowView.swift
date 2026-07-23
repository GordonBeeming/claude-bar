import ClaudeBarCore
import SwiftUI

struct LimitRowView: View {
    let limit: UsageLimit
    let now: Date
    let severity: Severity
    var displayMode: UsageDisplayMode = .used

    private let barHeight: CGFloat = 8
    private let markerWidth: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(LimitPresentation.displayName(for: limit))
                    .font(.subheadline)
                Spacer()
                Text("\(displayedPercent)%")
                    .font(.subheadline.bold())
            }

            paceBar

            if let resetsAt = limit.resetsAt {
                Text(
                    "Resets \(ResetFormatting.localResetString(for: resetsAt, now: now, timeZone: .current, locale: .current)) · \(ResetFormatting.countdownString(until: resetsAt, now: now))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if isOverPace {
                Text("🔥 Ahead of pace by \(aheadOfPacePercent)%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // Custom bar (not `ProgressView`) because the pace marker needs to be
    // positioned at an exact fraction of the track's width — `ProgressView`
    // doesn't expose a slot to overlay one.
    @ViewBuilder
    private var paceBar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                // Track and fill are plain rectangles clipped to a capsule together, so
                // the fill stays a rounded horizontal bar even at very low percentages.
                // A `Capsule` fill narrower than it is tall renders as a vertical pill
                // instead, which reads as a distorted blob at 1–2% usage.
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(.quaternary)

                    Rectangle()
                        .fill(tintColor)
                        .frame(width: width * fillFraction)
                }
                .clipShape(Capsule())

                // The marker sits outside the capsule clip so the rounded corners don't
                // trim it when the pace lands near either edge of the track.
                if let markerFraction, let paceFraction {
                    Rectangle()
                        .fill(Color.primary.opacity(0.6))
                        .frame(width: markerWidth)
                        .offset(x: markerOffset(fraction: markerFraction, width: width))
                        .accessibilityLabel("Steady pace")
                        .accessibilityValue("\(Int((paceFraction * 100).rounded())) percent of the window elapsed")
                }
            }
        }
        .frame(height: barHeight)
        .accessibilityLabel("Usage")
        .accessibilityValue(barAccessibilityValue)
    }

    private func markerOffset(fraction: Double, width: CGFloat) -> CGFloat {
        // Clamp so the marker never renders half off the track at either edge. Floor the
        // upper bound at 0: a transient layout pass with width < markerWidth would
        // otherwise make `width - markerWidth` negative and push the marker off-track.
        let maxOffset = max(width - markerWidth, 0)
        return min(max(width * fraction - markerWidth / 2, 0), maxOffset)
    }

    private var barAccessibilityValue: String {
        let base = displayMode == .fuelTank
            ? "\(displayedPercent) percent remaining"
            : "\(displayedPercent) percent"
        guard isOverPace else { return base }
        return base + ", ahead of pace by \(aheadOfPacePercent) percent"
    }

    /// The whole number shown in the row, flipped to fuel remaining in fuel-tank mode.
    private var displayedPercent: Int {
        Int(displayMode.displayPercent(usedPercent: limit.percent).rounded())
    }

    // Only meaningful when over pace; guard so a stray read when on/under pace can't
    // report a misleading "1". Floored at 1 otherwise, since once usage is past the
    // line the delta can round to 0 and "ahead of pace by 0%" reads as a bug.
    private var aheadOfPacePercent: Int {
        guard isOverPace else { return 0 }
        return max(1, Int(paceDelta.rounded()))
    }

    /// Fraction of the track to fill: used fraction normally, remaining fraction in
    /// fuel-tank mode so the bar drains as usage climbs.
    private var fillFraction: Double {
        displayMode.fillFraction(usedPercent: limit.percent)
    }

    private var paceFraction: Double? {
        UsageWindow.paceFraction(for: limit, now: now)
    }

    /// Where the steady-pace marker sits, mirrored in fuel-tank mode so "over pace" still
    /// reads as the fill falling short of the marker.
    private var markerFraction: Double? {
        paceFraction.map { displayMode.markerFraction(paceFraction: $0) }
    }

    private var paceDelta: Double {
        guard let paceFraction else { return 0 }
        return limit.percent - paceFraction * 100
    }

    private var isOverPace: Bool {
        UsageWindow.isOverPace(for: limit, now: now)
    }

    private var tintColor: Color {
        switch severity {
        case .normal: return .accentColor
        case .warning: return .orange
        case .critical: return .red
        }
    }
}
