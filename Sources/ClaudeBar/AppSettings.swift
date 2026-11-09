import ClaudeBarCore
import Foundation
import Observation
import OSLog

/// Where the usage token comes from. `claudeCode` (default) reads Claude Code's Keychain
/// item; `selfContained` uses our own OAuth sign-in and never reads Claude Code's item, so
/// it never triggers the Keychain prompt. If our sign-in fails, the menu asks to sign in again.
enum CredentialSource: String, CaseIterable, Sendable {
    case claudeCode
    case selfContained

    var label: String {
        switch self {
        case .claudeCode: return "Claude Code (default)"
        case .selfContained: return "Self-contained sign-in"
        }
    }
}

enum MenuBarPercentageSelection: Hashable {
    case highest
    case limit(String)

    private static let highestRawValue = "highest"
    private static let limitRawValuePrefix = "limit:"

    init(rawValue: String?) {
        guard let rawValue else {
            self = .highest
            return
        }

        if rawValue == Self.highestRawValue {
            self = .highest
        } else if rawValue.hasPrefix(Self.limitRawValuePrefix) {
            self = .limit(String(rawValue.dropFirst(Self.limitRawValuePrefix.count)))
        } else {
            self = .limit(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .highest:
            Self.highestRawValue
        case let .limit(key):
            Self.limitRawValuePrefix + key
        }
    }

    var limitSelectionKey: String? {
        switch self {
        case .highest:
            nil
        case let .limit(key):
            key
        }
    }
}

/// Which account the menu bar icon follows. Applies before `MenuBarPercentageSelection`,
/// which then picks the limit within that scope.
enum MenuBarAccountSelection: Hashable {
    case mostUsed
    case account(String)

    private static let mostUsedRawValue = "mostUsed"
    private static let accountRawValuePrefix = "account:"

    init(rawValue: String?) {
        guard let rawValue, rawValue.hasPrefix(Self.accountRawValuePrefix) else {
            self = .mostUsed
            return
        }
        let id = String(rawValue.dropFirst(Self.accountRawValuePrefix.count))
        self = id.isEmpty ? .mostUsed : .account(id)
    }

    var rawValue: String {
        switch self {
        case .mostUsed: Self.mostUsedRawValue
        case let .account(id): Self.accountRawValuePrefix + id
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let useClaudeSeverity = "useClaudeSeverity"
        static let warningThresholdPercent = "warningThresholdPercent"
        static let criticalThresholdPercent = "criticalThresholdPercent"
        static let menuBarPercentageSelection = "menuBarPercentageSelection"
        static let fuelTankMode = "fuelTankMode"
        static let showMenuBarFlame = "showMenuBarFlame"
        static let celebrationsEnabled = "celebrationsEnabled"
        /// The pre-multi-account global choice. Still read as the fallback for an account that
        /// has no choice of its own, which carries an existing install's choice over.
        static let legacyCredentialSource = "credentialSource"
        static let credentialSourcePrefix = "credentialSource."
        static let extraAccountFolders = "extraAccountFolders"
        static let menuBarAccountSelection = "menuBarAccountSelection"
        static let accountIDsByPath = "accountIDsByPath"
        static let telemetryEnabled = "telemetryEnabled"
        static let telemetryIntervalMinutes = "telemetryIntervalMinutes"
        static let telemetryRetentionDays = "telemetryRetentionDays"
        static let telemetryDirectory = "telemetryDirectory"
        static let telemetryFolderMigrated = "telemetryFolderMigrated"

        static func credentialSource(account id: String) -> String {
            credentialSourcePrefix + id
        }
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

    /// Off by default (percentages count up as usage). On flips every percentage and
    /// progress bar into "fuel remaining" that drains from full to empty.
    var fuelTankMode: Bool {
        didSet { defaults.set(fuelTankMode, forKey: Keys.fuelTankMode) }
    }

    /// The display direction the rest of the app renders with, derived from `fuelTankMode`.
    var usageDisplayMode: UsageDisplayMode {
        fuelTankMode ? .fuelTank : .used
    }

    var menuBarPercentageSelection: MenuBarPercentageSelection {
        didSet {
            defaults.set(menuBarPercentageSelection.rawValue, forKey: Keys.menuBarPercentageSelection)
        }
    }

    /// Master switch — off by default. The per-trigger toggles and effect choices below
    /// only take effect while this is on; they carry sensible defaults for when it is.
    var celebrationsEnabled: Bool {
        didSet { defaults.set(celebrationsEnabled, forKey: Keys.celebrationsEnabled) }
    }

    /// Only accounts the person has chosen a source for; the rest fall back to the legacy
    /// global choice. Held here (not read from defaults on demand) so observation tracks it.
    private var credentialSourceStore: [String: CredentialSource]
    private let legacyCredentialSource: CredentialSource

    /// Defaults to `.claudeCode` so existing installs behave exactly as before; the user
    /// opts into self-contained sign-in per account from Settings.
    func credentialSource(for accountID: String) -> CredentialSource {
        credentialSourceStore[accountID] ?? legacyCredentialSource
    }

    func setCredentialSource(_ source: CredentialSource, for accountID: String) {
        credentialSourceStore[accountID] = source
        defaults.set(source.rawValue, forKey: Keys.credentialSource(account: accountID))
    }

    /// Folders added in Settings, beyond what discovery finds on its own.
    private(set) var extraAccountFolders: [String]

    func addExtraAccountFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !extraAccountFolders.contains(path) else { return }
        extraAccountFolders.append(path)
        defaults.set(extraAccountFolders, forKey: Keys.extraAccountFolders)
    }

    func removeExtraAccountFolder(_ path: String) {
        extraAccountFolders.removeAll { $0 == path }
        defaults.set(extraAccountFolders, forKey: Keys.extraAccountFolders)
    }

    var extraAccountFolderURLs: [URL] {
        extraAccountFolders.map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    /// Folder path to account id, assigned the first time a folder is seen. Ids feed Keychain
    /// items, telemetry files and per-account settings, so they must stay with their folder.
    private(set) var accountIDsByPath: [String: String]

    /// Merge-only: a reservation is never dropped, and one already recorded for a path wins
    /// over a different id offered for it, so a late result can't undo an assignment.
    func recordAccountIDs(_ assignments: [String: String]) {
        let merged = ClaudeAccountDiscovery.mergeIDs(existing: accountIDsByPath, new: assignments)
        guard merged != accountIDsByPath else { return }
        accountIDsByPath = merged
        defaults.set(merged, forKey: Keys.accountIDsByPath)
    }

    var menuBarAccountSelection: MenuBarAccountSelection {
        didSet { defaults.set(menuBarAccountSelection.rawValue, forKey: Keys.menuBarAccountSelection) }
    }

    /// Opt-in: nothing is written to disk until the user turns this on.
    var telemetryEnabled: Bool {
        didSet { defaults.set(telemetryEnabled, forKey: Keys.telemetryEnabled) }
    }

    static let telemetryIntervalChoices = [1, 5, 15, 30, 60]

    var telemetryIntervalMinutes: Int {
        didSet { defaults.set(telemetryIntervalMinutes, forKey: Keys.telemetryIntervalMinutes) }
    }

    /// 0 is "keep forever"; UserDefaults can't store a nil Int.
    static let telemetryRetentionForever = 0
    static let telemetryRetentionChoices = [7, 30, 90, 180, 365, telemetryRetentionForever]

    var telemetryRetentionDays: Int {
        didSet { defaults.set(telemetryRetentionDays, forKey: Keys.telemetryRetentionDays) }
    }

    var telemetryDirectory: URL {
        didSet { defaults.set(telemetryDirectory.path, forKey: Keys.telemetryDirectory) }
    }

    var telemetryConfig: TelemetryConfig {
        TelemetryConfig(
            enabled: telemetryEnabled,
            intervalSeconds: TimeInterval(telemetryIntervalMinutes * 60),
            retentionDays: telemetryRetentionDays == Self.telemetryRetentionForever ? nil : telemetryRetentionDays,
            sinks: [.file(directory: telemetryDirectory)]
        )
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

    /// Moves telemetry out of the old Documents default. The flag is set only once nothing
    /// eligible remains there, so the Documents probe (which can raise a macOS prompt) stops
    /// happening on every launch, while a file that failed to move is retried next time.
    ///
    /// Returns the folder to use. The old default stored as the choice (from "Use default" in an
    /// earlier version) is cleared so the current default applies; a failed file is retried next
    /// launch because the flag stays unset and the new default is then what's stored.
    private static func migrateLegacyTelemetryFolder(selected: URL) -> URL {
        let defaults = UserDefaults.standard
        let home = FileManager.default.homeDirectoryForCurrentUser
        let outcome = TelemetryFolderMigration.migrateIfNeeded(
            selectedDirectory: selected,
            home: home,
            alreadyMigrated: defaults.bool(forKey: Keys.telemetryFolderMigrated)
        )
        if let outcome {
            let logger = Logger(subsystem: "com.gordonbeeming.ClaudeBar", category: "Telemetry")
            for failure in outcome.failures {
                logger.error("telemetry folder move: \(failure, privacy: .private)")
            }
            if outcome.isComplete { defaults.set(true, forKey: Keys.telemetryFolderMigrated) }
        }
        guard TelemetryFolderMigration.isLegacyDefault(selected, home: home) else { return selected }
        defaults.removeObject(forKey: Keys.telemetryDirectory)
        return TelemetryConfig.defaultDirectory
    }

    init() {
        // `register(defaults:)` (not `bool(forKey:)`/`double(forKey:)` fallbacks) so a
        // never-set `useClaudeSeverity` reads as `true` rather than `Bool`'s own
        // absent-key default of `false`.
        var registrations: [String: Any] = [
            Keys.useClaudeSeverity: true,
            Keys.warningThresholdPercent: 75.0,
            Keys.criticalThresholdPercent: 90.0,
            Keys.menuBarPercentageSelection: MenuBarPercentageSelection.highest.rawValue,
            Keys.fuelTankMode: false,
            Keys.showMenuBarFlame: true,
            Keys.celebrationsEnabled: false,
            Keys.legacyCredentialSource: CredentialSource.claudeCode.rawValue,
            Keys.menuBarAccountSelection: MenuBarAccountSelection.mostUsed.rawValue,
            Keys.telemetryEnabled: false,
            Keys.telemetryIntervalMinutes: Int(TelemetryConfig.defaultIntervalSeconds / 60),
            Keys.telemetryRetentionDays: TelemetryConfig.defaultRetentionDays,
            Keys.telemetryDirectory: TelemetryConfig.defaultDirectory.path
        ]
        // Each trigger defaults to enabled with its suggested effect, so once the
        // master switch is turned on the mapping is ready without further setup.
        for trigger in CelebrationTrigger.allCases {
            registrations[Keys.celebrationEnabled(trigger)] = true
            registrations[Keys.celebrationReaction(trigger)] = trigger.defaultReaction.rawValue
        }
        UserDefaults.standard.register(defaults: registrations)

        useClaudeSeverity = defaults.bool(forKey: Keys.useClaudeSeverity)
        menuBarPercentageSelection = MenuBarPercentageSelection(
            rawValue: defaults.string(forKey: Keys.menuBarPercentageSelection)
        )
        fuelTankMode = defaults.bool(forKey: Keys.fuelTankMode)
        showMenuBarFlame = defaults.bool(forKey: Keys.showMenuBarFlame)
        celebrationsEnabled = defaults.bool(forKey: Keys.celebrationsEnabled)
        legacyCredentialSource = defaults.string(forKey: Keys.legacyCredentialSource)
            .flatMap(CredentialSource.init(rawValue:)) ?? .claudeCode
        var sources: [String: CredentialSource] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(Keys.credentialSourcePrefix) {
            guard let raw = value as? String, let source = CredentialSource(rawValue: raw) else { continue }
            sources[String(key.dropFirst(Keys.credentialSourcePrefix.count))] = source
        }
        credentialSourceStore = sources
        extraAccountFolders = defaults.stringArray(forKey: Keys.extraAccountFolders) ?? []
        accountIDsByPath = defaults.dictionary(forKey: Keys.accountIDsByPath) as? [String: String] ?? [:]
        menuBarAccountSelection = MenuBarAccountSelection(rawValue: defaults.string(forKey: Keys.menuBarAccountSelection))

        telemetryEnabled = defaults.bool(forKey: Keys.telemetryEnabled)
        // Any in-range value is kept, not just the pickers' presets: Bar UI can ask for one
        // through the URL scheme, and it reads these keys back expecting what it asked for.
        let storedInterval = defaults.integer(forKey: Keys.telemetryIntervalMinutes)
        telemetryIntervalMinutes = TelemetryConfig.intervalMinutesRange.contains(storedInterval)
            ? storedInterval
            : Int(TelemetryConfig.defaultIntervalSeconds / 60)
        let storedRetention = defaults.integer(forKey: Keys.telemetryRetentionDays)
        telemetryRetentionDays = TelemetryConfig.retentionDaysRange.contains(storedRetention)
            ? storedRetention
            : TelemetryConfig.defaultRetentionDays
        let storedDirectory = defaults.string(forKey: Keys.telemetryDirectory) ?? ""
        let selectedDirectory = storedDirectory.isEmpty
            ? TelemetryConfig.defaultDirectory
            : URL(filePath: (storedDirectory as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        // Before anything can write: the recorder starts after settings exist.
        telemetryDirectory = Self.migrateLegacyTelemetryFolder(selected: selectedDirectory)

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
