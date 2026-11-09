import AppKit
import ClaudeBarCore
import Foundation
import Observation
import os

/// Coordinates the accounts: discovers them, polls each with its own credentials, and plays
/// one celebration per tick however many accounts earned it.
@MainActor
@Observable
final class UsageViewModel {
    private(set) var accounts: [AccountUsageModel] = []

    // `nonisolated(unsafe)` so `deinit` (always nonisolated for a class, without the
    // still-experimental `isolated deinit` feature) can tear them down directly.
    // Safe here: `Task.cancel()` and `NotificationCenter.removeObserver` are both
    // documented thread-safe, and nothing else touches these outside `@MainActor`.
    nonisolated(unsafe) private var pollTask: Task<Void, Never>?
    nonisolated(unsafe) private var wakeObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.gordonbeeming.ClaudeBar", category: "UsageViewModel")

    @ObservationIgnored private weak var settings: AppSettings?
    @ObservationIgnored private var celebrations: CelebrationController?
    private(set) var lastError: String?

    private static let didApplyDefaultLaunchAtLoginKey = "didApplyDefaultLaunchAtLogin"
    private static let staleThreshold: TimeInterval = 30

    init() {
        // The default account is there from the first frame, so the menu never opens empty;
        // the first poll's discovery adds any others.
        reconcile(with: [ClaudeAccount.standard()])
    }

    /// `SMAppService.mainApp.register()` throws outside a real `.app` bundle, so the
    /// toggle disables itself under a bare `swift run` binary instead of crashing.
    var launchAtLoginAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    // Stored (not computed) so `Observation` actually tracks it: a computed property
    // that only reads a static on another type registers no dependency, and the
    // toggle silently wouldn't reflect a reverted `oldValue` on failure.
    var launchAtLogin: Bool = LaunchAtLoginManager.isEnabled {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                try LaunchAtLoginManager.setEnabled(launchAtLogin)
            } catch {
                logger.error("launch-at-login toggle failed: \(error.localizedDescription, privacy: .public)")
                lastError = "Couldn't update launch at login: \(error.localizedDescription)"
                launchAtLogin = oldValue
            }
        }
    }

    var isRefreshing: Bool { accounts.contains(where: \.isRefreshing) }

    /// Every limit across accounts, for the Settings picker.
    var allLimits: [UsageLimit] { accounts.flatMap(\.limits) }

    func account(withID id: String) -> AccountUsageModel? {
        accounts.first { $0.id == id }
    }

    /// Idempotent: the menu bar label view calls this from `.onAppear`, which can
    /// fire more than once (e.g. the window being reopened), but polling should
    /// only ever run one loop.
    func startPolling() {
        guard pollTask == nil else { return }

        applyDefaultLaunchAtLoginIfNeeded()

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshAll()
            }
        }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Re-runs discovery first, so a new `~/.claude-accounts/x` shows up without a relaunch,
    /// then refreshes every account at once. Discovery reads the profile JSON, which can be
    /// large, so it runs off the main actor.
    func refreshAll() async {
        let result = await runDiscovery()
        reconcile(with: result.accounts)

        // Per account: identity first (accounts on their own sign-in are labelled by it, looked
        // up through the account's own single-flight refresh), then usage. Accounts run side by
        // side, so one stalled lookup delays only its own account.
        let reactions = await withTaskGroup(of: Set<ReactionChoice>.self) { group in
            for model in accounts {
                group.addTask {
                    await model.refreshSelfContainedIdentity()
                    return await model.refresh()
                }
            }
            var all: Set<ReactionChoice> = []
            for await reactions in group { all.formUnion(reactions) }
            return all
        }
        play(reactions)
    }

    /// Refreshes one account (or every one) from the menu's refresh button.
    func refresh(_ model: AccountUsageModel) async {
        play(await model.refresh())
    }

    /// Called on menu open so a stale cache refreshes without making the open feel
    /// laggy — the menu renders the cached `limits` instantly, and this update
    /// lands whenever the fetch completes.
    func refreshIfStale() {
        let stale = accounts.filter { $0.isStale(threshold: Self.staleThreshold) }
        guard !stale.isEmpty else { return }
        Task {
            let reactions = await withTaskGroup(of: Set<ReactionChoice>.self) { group in
                for model in stale {
                    group.addTask { await model.refresh() }
                }
                var all: Set<ReactionChoice> = []
                for await reactions in group { all.formUnion(reactions) }
                return all
            }
            play(reactions)
        }
    }

    /// Wires up celebrations. Called from the menu-bar label's `.onAppear` (which holds
    /// both the settings and the controller) alongside `startPolling()`.
    func attachCelebrations(settings: AppSettings, controller: CelebrationController) {
        self.settings = settings
        self.celebrations = controller
        for model in accounts { model.settings = settings }
    }

    /// Plays an effect immediately, ignoring the enable/seed gating — for the Settings
    /// "Test" buttons.
    func previewCelebration(_ choice: ReactionChoice) {
        celebrations?.play(choice)
    }

    // MARK: Menu bar icon

    /// The limit the icon shows: within the chosen account scope, the selected limit (or the
    /// highest), then the highest of those across the accounts in scope.
    func menuBarLimit(accountSelection: MenuBarAccountSelection, limitKey: String?) -> UsageLimit? {
        let scoped = accountsInScope(accountSelection)
        let candidates = scoped.compactMap { ClaudeBarCore.menuBarLimit(in: $0.limits, selectedKey: limitKey) }
        return highestLimit(in: candidates)
    }

    /// The limits the over-pace flame looks at: every limit in the icon's account scope.
    func limitsInScope(_ selection: MenuBarAccountSelection) -> [UsageLimit] {
        accountsInScope(selection).flatMap(\.limits)
    }

    /// A pinned account with no data yet (or one that no longer exists) falls back to every
    /// account, so the icon never goes blank while another account has numbers.
    private func accountsInScope(_ selection: MenuBarAccountSelection) -> [AccountUsageModel] {
        guard case let .account(id) = selection,
              let pinned = account(withID: id),
              !pinned.limits.isEmpty else {
            return accounts
        }
        return [pinned]
    }

    // MARK: Accounts

    /// Runs discovery one at a time. Id allocation reads the known ids and records new ones,
    /// so two overlapping runs could each allocate from the same snapshot; chaining them means
    /// every run starts from everything the previous one reserved.
    @ObservationIgnored private var lastDiscovery: Task<ClaudeAccountDiscovery.Result, Never>?

    private func runDiscovery() async -> ClaudeAccountDiscovery.Result {
        let previous = lastDiscovery
        let task = Task { @MainActor [weak self] () -> ClaudeAccountDiscovery.Result in
            _ = await previous?.value
            let home = FileManager.default.homeDirectoryForCurrentUser
            let extraFolders = self?.settings?.extraAccountFolderURLs ?? []
            let knownIDs = self?.settings?.accountIDsByPath ?? [:]
            let result = await Task.detached {
                ClaudeAccountDiscovery.discover(home: home, extraFolders: extraFolders, knownIDs: knownIDs)
            }.value
            self?.settings?.recordAccountIDs(result.idsByPath)
            return result
        }
        lastDiscovery = task
        return await task.value
    }

    private func reconcile(with discovered: [ClaudeAccount]) {
        let existing = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let next = discovered.map { account -> AccountUsageModel in
            if let model = existing[account.id] {
                model.update(account: account)
                return model
            }
            logger.notice("watching account \(account.id, privacy: .public)")
            return AccountUsageModel(account: account, settings: settings)
        }
        for gone in accounts where !next.contains(where: { $0.id == gone.id }) {
            logger.notice("account \(gone.id, privacy: .public) is gone")
        }
        // Avoid invalidating the menu on every poll when nothing changed.
        if next.map(\.id) != accounts.map(\.id) || zip(next, accounts).contains(where: { $0 !== $1 }) {
            accounts = next
        }
    }

    private func play(_ reactions: Set<ReactionChoice>) {
        guard !reactions.isEmpty else { return }
        let fired = reactions.map(\.rawValue).sorted().joined(separator: ",")
        logger.notice("celebrations fired: \(fired, privacy: .public)")
        for reaction in reactions { celebrations?.play(reaction) }
    }

    private func applyDefaultLaunchAtLoginIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.didApplyDefaultLaunchAtLoginKey) else { return }

        // Only consume the one-shot flag when running as a real .app — a bare
        // `swift run` session must not burn it, or the installed app would never
        // get its default-ON registration.
        guard launchAtLoginAvailable else { return }
        do {
            try LaunchAtLoginManager.setEnabled(true)
            launchAtLogin = true
            // Only consume the one-shot flag once registration actually succeeds,
            // so a transient failure (e.g. OS prompt/permissions timing) gets
            // retried on the next launch instead of being silently given up on.
            defaults.set(true, forKey: Self.didApplyDefaultLaunchAtLoginKey)
        } catch {
            // Best-effort default: a bare `swift run` binary or a first launch before
            // Gordon has granted anything shouldn't be treated as an error state.
            logger.error("default launch-at-login registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    deinit {
        pollTask?.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }
}
