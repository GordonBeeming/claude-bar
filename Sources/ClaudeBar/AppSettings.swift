import ClaudeBarCore
import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let useClaudeSeverity = "useClaudeSeverity"
        static let warningThresholdPercent = "warningThresholdPercent"
        static let criticalThresholdPercent = "criticalThresholdPercent"
    }

    private let defaults = UserDefaults.standard

    var useClaudeSeverity: Bool {
        didSet { defaults.set(useClaudeSeverity, forKey: Keys.useClaudeSeverity) }
    }

    var warningThresholdPercent: Double {
        didSet { defaults.set(warningThresholdPercent, forKey: Keys.warningThresholdPercent) }
    }

    var criticalThresholdPercent: Double {
        didSet { defaults.set(criticalThresholdPercent, forKey: Keys.criticalThresholdPercent) }
    }

    var thresholds: SeverityThresholds {
        SeverityThresholds(
            useClaudeSeverity: useClaudeSeverity,
            warningPercent: warningThresholdPercent,
            criticalPercent: criticalThresholdPercent
        )
    }

    init() {
        // `register(defaults:)` (not `bool(forKey:)`/`double(forKey:)` fallbacks) so a
        // never-set `useClaudeSeverity` reads as `true` rather than `Bool`'s own
        // absent-key default of `false`.
        UserDefaults.standard.register(defaults: [
            Keys.useClaudeSeverity: true,
            Keys.warningThresholdPercent: 75.0,
            Keys.criticalThresholdPercent: 90.0
        ])

        useClaudeSeverity = defaults.bool(forKey: Keys.useClaudeSeverity)
        warningThresholdPercent = defaults.double(forKey: Keys.warningThresholdPercent)
        criticalThresholdPercent = defaults.double(forKey: Keys.criticalThresholdPercent)
    }
}
