import ClaudeBarCore
import SwiftUI

struct LimitRowView: View {
    let limit: UsageLimit
    let now: Date
    let severity: Severity

    private let barHeight: CGFloat = 8
    private let markerWidth: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(LimitPresentation.displayName(for: limit))
                    .font(.subheadline)
                Spacer()
                Text("\(Int(limit.percent.rounded()))%")
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
                Text("🔥 Ahead of pace by \(Int(paceDelta.rounded()))%")
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
                Capsule()
                    .fill(.quaternary)

                Capsule()
                    .fill(tintColor)
                    .frame(width: width * clampedPercent / 100)

                if let paceFraction {
                    Rectangle()
                        .fill(Color.primary.opacity(0.6))
                        .frame(width: markerWidth)
                        .offset(x: markerOffset(paceFraction: paceFraction, width: width))
                        .accessibilityLabel("Steady pace")
                        .accessibilityValue("\(Int((paceFraction * 100).rounded())) percent of the window elapsed")
                }
            }
        }
        .frame(height: barHeight)
        .accessibilityLabel("Usage")
        .accessibilityValue(barAccessibilityValue)
    }

    private func markerOffset(paceFraction: Double, width: CGFloat) -> CGFloat {
        // Clamp so the marker itself never renders half off the track at either edge.
        min(max(width * paceFraction - markerWidth / 2, 0), width - markerWidth)
    }

    private var barAccessibilityValue: String {
        let base = "\(Int(limit.percent.rounded())) percent"
        guard isOverPace else { return base }
        return base + ", ahead of pace by \(Int(paceDelta.rounded())) percent"
    }

    private var clampedPercent: Double {
        min(max(limit.percent, 0), 100)
    }

    private var paceFraction: Double? {
        UsageWindow.paceFraction(for: limit, now: now)
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
