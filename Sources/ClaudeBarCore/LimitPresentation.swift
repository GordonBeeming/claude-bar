import Foundation

/// Kind-string → human display, and the menu's row ordering. Isolated from
/// `UsageModels` so new/unknown API kinds degrade gracefully instead of failing decode.
public enum LimitPresentation {
    public static func displayName(for limit: UsageLimit) -> String {
        switch limit.kind {
        case "session":
            return "Session (5h)"
        case "weekly_all":
            return "Weekly (all models)"
        case "weekly_scoped":
            if let modelName = limit.scope?.model?.displayName, !modelName.isEmpty {
                return "Weekly — \(modelName)"
            }
            return "Weekly (scoped)"
        default:
            let humanized = humanize(limit.kind)
            if let modelName = limit.scope?.model?.displayName, !modelName.isEmpty {
                return "\(humanized) — \(modelName)"
            }
            return humanized
        }
    }

    /// Best-effort label for a kind we've never seen: "monthly_all" → "Monthly all".
    private static func humanize(_ kind: String) -> String {
        let spaced = kind.replacingOccurrences(of: "_", with: " ")
        guard let first = spaced.first else { return spaced }
        return first.uppercased() + spaced.dropFirst()
    }

    /// Session first, then weekly, then any other groups alphabetically; percent
    /// descending within a group, kind as the final tie-break for stability.
    public static func sorted(_ limits: [UsageLimit]) -> [UsageLimit] {
        limits.sorted { lhs, rhs in
            let (lhsTier, lhsGroup) = groupOrdering(lhs)
            let (rhsTier, rhsGroup) = groupOrdering(rhs)

            if lhsTier != rhsTier {
                return lhsTier < rhsTier
            }
            if lhsTier == .other && lhsGroup != rhsGroup {
                return lhsGroup < rhsGroup
            }
            if lhs.percent != rhs.percent {
                return lhs.percent > rhs.percent
            }
            return lhs.kind < rhs.kind
        }
    }

    private enum GroupTier: Int, Comparable {
        case session = 0
        case weekly = 1
        case other = 2

        static func < (lhs: GroupTier, rhs: GroupTier) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    private static func groupOrdering(_ limit: UsageLimit) -> (GroupTier, String) {
        switch limit.group {
        case "session": return (.session, "")
        case "weekly": return (.weekly, "")
        default: return (.other, limit.group ?? "")
        }
    }
}
