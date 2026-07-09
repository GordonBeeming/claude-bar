import Foundation

/// One of the reaction effects a celebration can play. Mirrors the MacReactions
/// library's built-in set by raw value so `ClaudeBarCore` stays dependency-free and
/// unit-testable; the app maps each case onto the library's `Reaction`.
public enum ReactionChoice: String, CaseIterable, Sendable {
    case confetti
    case balloons
    case fireworks
    case rain
    case lasers
    case hearts
    case thumbsUp
    case thumbsDown

    public var displayName: String {
        switch self {
        case .confetti: return "Confetti"
        case .balloons: return "Balloons"
        case .fireworks: return "Fireworks"
        case .rain: return "Rain"
        case .lasers: return "Lasers"
        case .hearts: return "Hearts"
        case .thumbsUp: return "Thumbs up"
        case .thumbsDown: return "Thumbs down"
        }
    }
}

/// A usage event worth reacting to. Each maps to a settings toggle + effect picker.
public enum CelebrationTrigger: String, CaseIterable, Sendable {
    /// The 5-hour session window rolled over — a fresh allowance.
    case sessionReset
    /// The weekly (all-models) window rolled over.
    case weeklyReset
    /// Weekly usage just crossed over its steady pace — a warning, not a celebration.
    case overWeeklyPace

    public var displayName: String {
        switch self {
        case .sessionReset: return "Session (5h) reset"
        case .weeklyReset: return "Weekly reset"
        case .overWeeklyPace: return "Burning over weekly pace"
        }
    }

    /// The reaction a trigger uses until the user picks another one.
    public var defaultReaction: ReactionChoice {
        switch self {
        case .sessionReset: return .confetti
        case .weeklyReset: return .fireworks
        case .overWeeklyPace: return .rain
        }
    }
}

/// What a limit looked like on the previous poll, enough to detect the transitions
/// that fire a celebration without re-deriving them from the raw limit each time.
public struct LimitSnapshot: Sendable {
    public let resetsAt: Date?
    public let percent: Double
    public let overPace: Bool

    public init(resetsAt: Date?, percent: Double, overPace: Bool) {
        self.resetsAt = resetsAt
        self.percent = percent
        self.overPace = overPace
    }
}

/// How far usage must fall between polls to count as a reset, and the level it must land
/// under. `resetsAt` jumps proved too noisy to key on (phantom weekly fireworks, hourly
/// phantom session confetti), so detection keys on the drop in usage instead. Public so the
/// diagnostic logging can reuse the same numbers instead of duplicating them.
public let resetDropThreshold = 25.0
public let resetFloor = 10.0

/// Pure diff of the previous poll against the current one → the set of triggers that
/// just fired. A limit with no `previous` snapshot (first-seen, or the very first poll
/// after launch) never fires, so a relaunch can't replay a reset that already happened.
public func detectCelebrationEvents(
    previous: [String: LimitSnapshot],
    current: [UsageLimit],
    now: Date
) -> Set<CelebrationTrigger> {
    var fired: Set<CelebrationTrigger> = []

    // Keys that appear on more than one limit this poll are genuinely indistinguishable
    // (e.g. two scoped limits with no model name); we can't tell which previous snapshot
    // belongs to which, so we skip celebrating those rather than guess and misfire.
    let ambiguousKeys = Set(
        Dictionary(grouping: current, by: \.celebrationKey)
            .filter { $0.value.count > 1 }
            .keys
    )

    for limit in current {
        guard !ambiguousKeys.contains(limit.celebrationKey) else { continue }
        guard let prev = previous[limit.celebrationKey] else { continue }

        // A reset is a fresh allowance, and usage only ever climbs within a window — so a
        // sharp drop is the unambiguous signal that the window rolled, including the
        // ad-hoc server-side resets Anthropic sometimes does that a `resetsAt` jump can
        // miss. Require both the drop to clear `resetDropThreshold` and the new level to
        // sit under `resetFloor`, so a mid-range dip can't trip it. `resetsAt` is left out
        // of reset detection entirely (it stays only for pace) because its jumps are noisy
        // — a transient API value or a scoped-limit `id` collision fired phantom resets.
        if prev.percent - limit.percent > resetDropThreshold, limit.percent < resetFloor {
            switch limit.group {
            case "session": fired.insert(.sessionReset)
            case "weekly": fired.insert(.weeklyReset)
            default: break
            }
        }

        if limit.group == "weekly" {
            let curOverPace = UsageWindow.isOverPace(for: limit, now: now)
            if curOverPace && !prev.overPace {
                fired.insert(.overWeeklyPace)
            }
        }
    }
    return fired
}
