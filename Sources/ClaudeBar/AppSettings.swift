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
        static let celebrationsEnabled = "celebrationsEnabled"

        static func celebrationEnabled(_ trigger: CelebrationTrigger) -> String {
            "celebration.\(trigger.rawValue).enabled"
        }
        static func celebrationReaction(_ trigger: CelebrationTrigger) -> String {
            "celebration.\(trigger.rawValue).reaction"
        }
    }

    private let defaults = UserDefaults.standard

    var useClaudeSeverity: Bool {
        didSet { defaults.set(useClaudeSeverity, forKey: Keys.useClaudeSeverity) }
    }

    /// Whether the menu-bar icon shows the 🔥 flame when a limit is burning over pace.
    var showMenuBarFlame: Bool {
        didSet { defaults.set(showMenuBarFlame, forKey: Keys.showMenuBarFlame) }
    }

    /// Master switch — off by default. The per-trigger toggles and effect choices below
    /// only take effect while this is on; they carry sensible defaults for when it is.
    var celebrationsEnabled: Bool {
        didSet { defaults.set(celebrationsEnabled, forKey: Keys.celebrationsEnabled) }
    }

    // Per-trigger enabled/reaction live in dictionaries (rather than six explicit
    // properties) so the trigger list stays the single source of truth; the accessors
    // below read/write them and observation tracks the whole store.
    private var celebrationEnabledStore: [String: Bool]
    private var celebrationReactionStore: [String: ReactionChoice]

    func celebrationEnabled(for trigger: CelebrationTrigger) -> Bool {
        celebrationEnabledStore[trigger.rawValue] ?? true
    }

    func setCelebrationEnabled(_ enabled: Bool, for trigger: CelebrationTrigger) {
        celebrationEnabledStore[trigger.rawValue] = enabled
        defaults.set(enabled, forKey: Keys.celebrationEnabled(trigger))
    }

    func reaction(for trigger: CelebrationTrigger) -> ReactionChoice {
        celebrationReactionStore[trigger.rawValue] ?? trigger.defaultReaction
    }

    func setReaction(_ reaction: ReactionChoice, for trigger: CelebrationTrigger) {
        celebrationReactionStore[trigger.rawValue] = reaction
        defaults.set(reaction.rawValue, forKey: Keys.celebrationReaction(trigger))
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
        var registrations: [String: Any] = [
            Keys.useClaudeSeverity: true,
            Keys.warningThresholdPercent: 75.0,
            Keys.criticalThresholdPercent: 90.0,
            Keys.showMenuBarFlame: true,
            Keys.celebrationsEnabled: false
        ]
        // Each trigger defaults to enabled with its suggested effect, so once the
        // master switch is turned on the mapping is ready without further setup.
        for trigger in CelebrationTrigger.allCases {
            registrations[Keys.celebrationEnabled(trigger)] = true
            registrations[Keys.celebrationReaction(trigger)] = trigger.defaultReaction.rawValue
        }
        UserDefaults.standard.register(defaults: registrations)

        useClaudeSeverity = defaults.bool(forKey: Keys.useClaudeSeverity)
        showMenuBarFlame = defaults.bool(forKey: Keys.showMenuBarFlame)
        celebrationsEnabled = defaults.bool(forKey: Keys.celebrationsEnabled)

        var enabledStore: [String: Bool] = [:]
        var reactionStore: [String: ReactionChoice] = [:]
        for trigger in CelebrationTrigger.allCases {
            enabledStore[trigger.rawValue] = defaults.bool(forKey: Keys.celebrationEnabled(trigger))
            // Fall back to the trigger's default if the stored raw is an unknown value
            // (e.g. an effect removed from a future library, or hand-edited defaults).
            let rawReaction = defaults.string(forKey: Keys.celebrationReaction(trigger))
            reactionStore[trigger.rawValue] = rawReaction.flatMap(ReactionChoice.init(rawValue:)) ?? trigger.defaultReaction
        }
        celebrationEnabledStore = enabledStore
        celebrationReactionStore = reactionStore

        // Assign the backing fields directly — property observers don't run during
        // init, so going through the computed setters above would skip the clamp.
        _warningThresholdPercent = Self.clamp(defaults.double(forKey: Keys.warningThresholdPercent))
        _criticalThresholdPercent = Self.clamp(defaults.double(forKey: Keys.criticalThresholdPercent))
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 1), 100)
    }
}
