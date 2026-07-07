import ClaudeBarCore
import SwiftUI

struct LimitRowView: View {
    let limit: UsageLimit
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(LimitPresentation.displayName(for: limit))
                    .font(.subheadline)
                Spacer()
                Text("\(Int(limit.percent.rounded()))%")
                    .font(.subheadline.bold())
            }

            ProgressView(value: min(max(limit.percent, 0), 100), total: 100)
                .tint(tintColor)

            if let resetsAt = limit.resetsAt {
                Text(
                    "Resets \(ResetFormatting.localResetString(for: resetsAt, now: now, timeZone: .current, locale: .current)) · \(ResetFormatting.countdownString(until: resetsAt, now: now))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var tintColor: Color {
        switch limit.severity {
        case .normal: return .accentColor
        case .warning: return .orange
        case .critical: return .red
        }
    }
}
