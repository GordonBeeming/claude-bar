import Foundation

/// The steady-pace line for a windowed limit: where usage *would* be if the
/// allowance were spent evenly across the window, so a fast burn (a lot used,
/// early in the window) is visible alongside the raw percent.
public enum UsageWindow {
    private static let sessionDuration: TimeInterval = 5 * 3600
    private static let weeklyDuration: TimeInterval = 7 * 86400

    /// Fixed window length per `UsageLimit.group`. nil for an unknown group (e.g.
    /// "other") — there's no fixed cadence to pace against.
    public static func duration(forGroup group: String?) -> TimeInterval? {
        switch group {
        case "session": return sessionDuration
        case "weekly": return weeklyDuration
        default: return nil
        }
    }

    /// Elapsed fraction of the window (0…1), or nil when the group is unknown or
    /// `resetsAt` is missing. The API only ever gives the window's end, so the
    /// start is derived as `resetsAt - duration`.
    public static func paceFraction(for limit: UsageLimit, now: Date) -> Double? {
        guard let duration = duration(forGroup: limit.group), let resetsAt = limit.resetsAt else {
            return nil
        }
        let start = resetsAt.addingTimeInterval(-duration)
        let fraction = now.timeIntervalSince(start) / duration
        return min(max(fraction, 0), 1)
    }

    /// True when actual usage is ahead of the steady-pace line by more than
    /// `marginPercent` — a small margin absorbs normal bursty usage instead of
    /// flagging every limit that's a couple of percent ahead.
    public static func isOverPace(for limit: UsageLimit, now: Date, marginPercent: Double = 5) -> Bool {
        guard let fraction = paceFraction(for: limit, now: now) else { return false }
        return limit.percent - fraction * 100 > marginPercent
    }
}
