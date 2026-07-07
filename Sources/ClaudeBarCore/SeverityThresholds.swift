import Foundation

/// User-configurable rule for turning a limit's percent into a `Severity`, as an
/// alternative to trusting the API's own `severity` field.
public struct SeverityThresholds: Sendable, Equatable {
    public var useClaudeSeverity: Bool

    // Clamped on every write (not just at init) so a caller assigning an
    // out-of-range value directly — e.g. a settings text field mid-edit — can never
    // produce a threshold `resolve` would misbehave on.
    public var warningPercent: Double {
        didSet {
            let clamped = Self.clamp(warningPercent)
            // didSet fires unconditionally on assignment, so guard the no-op case —
            // otherwise re-assigning the already-clamped value recurses forever.
            if clamped != warningPercent { warningPercent = clamped }
        }
    }
    public var criticalPercent: Double {
        didSet {
            let clamped = Self.clamp(criticalPercent)
            if clamped != criticalPercent { criticalPercent = clamped }
        }
    }

    public init(
        useClaudeSeverity: Bool = true,
        warningPercent: Double = 75,
        criticalPercent: Double = 90
    ) {
        self.useClaudeSeverity = useClaudeSeverity
        self.warningPercent = Self.clamp(warningPercent)
        self.criticalPercent = Self.clamp(criticalPercent)
    }

    public func resolve(for limit: UsageLimit) -> Severity {
        guard !useClaudeSeverity else { return limit.severity }

        // A caller could set warning above critical (e.g. mid-edit in the settings
        // UI); treat critical as never lower than warning rather than producing an
        // unreachable warning band.
        let critical = max(warningPercent, criticalPercent)
        if limit.percent >= critical {
            return .critical
        } else if limit.percent >= warningPercent {
            return .warning
        } else {
            return .normal
        }
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 1), 100)
    }
}
