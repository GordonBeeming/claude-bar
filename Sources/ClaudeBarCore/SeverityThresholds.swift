import Foundation

/// User-configurable rule for turning a limit's percent into a `Severity`, as an
/// alternative to trusting the API's own `severity` field.
public struct SeverityThresholds: Sendable, Equatable {
    public var useClaudeSeverity: Bool

    // Backed by a private stored property so clamping happens in the setter rather
    // than a self-mutating `didSet` — a caller assigning an out-of-range value
    // directly (e.g. a settings text field mid-edit) can never produce a threshold
    // `resolve` would misbehave on.
    private var _warningPercent: Double
    public var warningPercent: Double {
        get { _warningPercent }
        set { _warningPercent = Self.clamp(newValue) }
    }

    private var _criticalPercent: Double
    public var criticalPercent: Double {
        get { _criticalPercent }
        set { _criticalPercent = Self.clamp(newValue) }
    }

    public init(
        useClaudeSeverity: Bool = true,
        warningPercent: Double = 75,
        criticalPercent: Double = 90
    ) {
        self.useClaudeSeverity = useClaudeSeverity
        self._warningPercent = Self.clamp(warningPercent)
        self._criticalPercent = Self.clamp(criticalPercent)
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
