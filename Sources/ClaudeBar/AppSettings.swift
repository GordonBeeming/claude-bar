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
        static let showMenuBarFlame = "showMenuBarFlame"
    }

    private let defaults = UserDefaults.standard

    var useClaudeSeverity: Bool {
        didSet { defaults.set(useClaudeSeverity, forKey: Keys.useClaudeSeverity) }
    }

    /// Whether the menu-bar icon shows the 🔥 flame when a limit is burning over pace.
    var showMenuBarFlame: Bool {
        didSet { defaults.set(showMenuBarFlame, forKey: Keys.showMenuBarFlame) }
    }

    // Backed by a private stored property so clamping applies to every write,
    // including the value loaded from UserDefaults at init — a corrupted or
    // externally-edited defaults entry could otherwise feed an out-of-range value
    // straight into ThresholdBarView's bindings.
    private var _warningThresholdPercent: Double
    var warningThresholdPercent: Double {
        get { _warningThresholdPercent }
        set {
            _warningThresholdPercent = Self.clamp(newValue)
            defaults.set(_warningThresholdPercent, forKey: Keys.warningThresholdPercent)
        }
    }

    private var _criticalThresholdPercent: Double
    var criticalThresholdPercent: Double {
        get { _criticalThresholdPercent }
        set {
            _criticalThresholdPercent = Self.clamp(newValue)
            defaults.set(_criticalThresholdPercent, forKey: Keys.criticalThresholdPercent)
        }
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
            Keys.criticalThresholdPercent: 90.0,
            Keys.showMenuBarFlame: true
        ])

        useClaudeSeverity = defaults.bool(forKey: Keys.useClaudeSeverity)
        showMenuBarFlame = defaults.bool(forKey: Keys.showMenuBarFlame)
        // Assign the backing fields directly — property observers don't run during
        // init, so going through the computed setters above would skip the clamp.
        _warningThresholdPercent = Self.clamp(defaults.double(forKey: Keys.warningThresholdPercent))
        _criticalThresholdPercent = Self.clamp(defaults.double(forKey: Keys.criticalThresholdPercent))
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 1), 100)
    }
}
