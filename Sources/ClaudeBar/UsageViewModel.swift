import AppKit
import ClaudeBarCore
import Foundation
import Observation
import os

/// Read-only auth means the app never tries to fix an expired/missing token itself —
/// this just tells the menu what to say, and `refresh()` keeps the last-known data
/// on screen either way.
enum AuthState: Sendable {
    case ok
    case tokenExpired
    case noToken
}

@MainActor
@Observable
final class UsageViewModel {
    private(set) var limits: [UsageLimit] = []
    private(set) var lastUpdated: Date?
    private(set) var authState: AuthState = .ok
    private(set) var lastError: String?
    private(set) var isRefreshing = false

    private let service = UsageService()
    // `nonisolated(unsafe)` so `deinit` (always nonisolated for a class, without the
    // still-experimental `isolated deinit` feature) can tear them down directly.
    // Safe here: `Task.cancel()` and `NotificationCenter.removeObserver` are both
    // documented thread-safe, and nothing else touches these outside `@MainActor`.
    nonisolated(unsafe) private var pollTask: Task<Void, Never>?
    nonisolated(unsafe) private var wakeObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.gordonbeeming.ClaudeBar", category: "UsageViewModel")

    // Celebrations: compare each poll's limits against the last to spot resets and the
    // over-pace crossing. Kept out of `@Observable` tracking (plain refs, not observed
    // state) — nothing in the UI renders from them.
    @ObservationIgnored private var previousSnapshots: [String: LimitSnapshot] = [:]
    @ObservationIgnored private var hasSeededCelebrations = false
    @ObservationIgnored private weak var settings: AppSettings?
    @ObservationIgnored private var celebrations: CelebrationController?

    private static let didApplyDefaultLaunchAtLoginKey = "didApplyDefaultLaunchAtLogin"
    private static let staleThreshold: TimeInterval = 30

    var highest: UsageLimit? {
        highestLimit(in: limits)
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
                await self?.refresh()
            }
        }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Never blocks the UI: all Keychain/network work happens inside the
    /// `UsageService` actor, and the menu keeps rendering whatever `limits`
    /// already holds while this runs.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let preferSelfContained = settings?.credentialSource == .selfContained
            let response = try await service.fetch(preferSelfContained: preferSelfContained)
            limits = response.limits
            lastUpdated = Date()
            authState = .ok
            lastError = nil
            processCelebrations(for: response.limits, now: Date())
        } catch UsageClient.UsageError.unauthorized {
            authState = .tokenExpired
            lastError = nil
        } catch UsageClient.UsageError.noToken {
            authState = .noToken
            lastError = nil
        } catch {
            logger.error("usage refresh failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Couldn't refresh: \(error.localizedDescription)"
        }
    }

    /// Called on menu open so a stale cache refreshes without making the open feel
    /// laggy — the menu renders the cached `limits` instantly, and this update
    /// lands whenever the fetch completes.
    func refreshIfStale() {
        let isStale = lastUpdated.map { Date().timeIntervalSince($0) > Self.staleThreshold } ?? true
        guard isStale else { return }
        Task { await refresh() }
    }

    /// Wires up celebrations. Called from the menu-bar label's `.onAppear` (which holds
    /// both the settings and the controller) alongside `startPolling()`.
    func attachCelebrations(settings: AppSettings, controller: CelebrationController) {
        self.settings = settings
        self.celebrations = controller
    }

    /// Plays an effect immediately, ignoring the enable/seed gating — for the Settings
    /// "Test" buttons.
    func previewCelebration(_ choice: ReactionChoice) {
        celebrations?.play(choice)
    }

    private func processCelebrations(for limits: [UsageLimit], now: Date) {
        let snapshots = Dictionary(
            limits.map { limit in
                (limit.celebrationKey, LimitSnapshot.next(
                    after: previousSnapshots[limit.celebrationKey],
                    for: limit,
                    now: now
                ))
            },
            // `celebrationKey` (kind + model id + name) keeps distinct models apart, unlike
            // `id`. Two limits that still share a key are indistinguishable; last one wins
            // here and the detector skips ambiguous keys, so neither can fire a phantom reset.
            uniquingKeysWith: { _, latest in latest }
        )
        defer { previousSnapshots = snapshots }

        // The first successful poll only seeds the baseline — never fires. This also
        // means a relaunch won't replay a reset that happened while the app was closed.
        guard hasSeededCelebrations else {
            hasSeededCelebrations = true
            return
        }

        // Usage falling between polls is the reset signal (usage otherwise only climbs).
        // Log any material drop — with prev/cur percent and whether it met the reset rule
        // — so ad-hoc server-side resets and threshold tuning stay observable in Console
        // instead of needing live-API detective work to reconstruct.
        // Surface near-misses too: this floor sits below the reset threshold on purpose, so
        // a drop that didn't quite reset still shows up for tuning.
        let diagnosticDropFloor = 15.0
        for limit in limits where UsageWindow.duration(forGroup: limit.group) != nil {
            guard let prev = previousSnapshots[limit.celebrationKey] else { continue }
            let drop = prev.percent - limit.percent
            let countedAsReset = usageDidReset(from: prev.percent, to: limit.percent)
            guard countedAsReset || drop > diagnosticDropFloor else { continue }
            logger.notice("""
                usage dropped \(drop, privacy: .public) points for \
                \(limit.id, privacy: .public) — \(prev.percent, privacy: .public)% → \
                \(limit.percent, privacy: .public)% — \
                \(countedAsReset ? "counted as reset" : "below reset threshold", privacy: .public)
                """)
        }

        guard let settings, settings.celebrationsEnabled else { return }

        let events = detectCelebrationEvents(previous: previousSnapshots, current: limits, now: now)
        let reactions = Set(
            events
                .filter { settings.celebrationEnabled(for: $0) }
                .map { settings.reaction(for: $0) }
        )
        if !reactions.isEmpty {
            let fired = events.map(\.rawValue).sorted().joined(separator: ",")
            logger.notice("celebrations fired: \(fired, privacy: .public)")
        }
        for reaction in reactions {
            celebrations?.play(reaction)
        }
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
