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
    private var pollTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.gordonbeeming.ClaudeBar", category: "UsageViewModel")

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

    var launchAtLogin: Bool {
        get { LaunchAtLoginManager.isEnabled }
        set {
            do {
                try LaunchAtLoginManager.setEnabled(newValue)
            } catch {
                logger.error("launch-at-login toggle failed: \(error.localizedDescription, privacy: .public)")
                lastError = "Couldn't update launch at login: \(error.localizedDescription)"
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
            let response = try await service.fetch()
            limits = response.limits
            lastUpdated = Date()
            authState = .ok
            lastError = nil
        } catch UsageClient.UsageError.unauthorized {
            authState = .tokenExpired
        } catch UsageClient.UsageError.noToken {
            authState = .noToken
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

    private func applyDefaultLaunchAtLoginIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.didApplyDefaultLaunchAtLoginKey) else { return }

        // Only consume the one-shot flag when running as a real .app — a bare
        // `swift run` session must not burn it, or the installed app would never
        // get its default-ON registration.
        guard launchAtLoginAvailable else { return }
        defaults.set(true, forKey: Self.didApplyDefaultLaunchAtLoginKey)
        do {
            try LaunchAtLoginManager.setEnabled(true)
        } catch {
            // Best-effort default: a bare `swift run` binary or a first launch before
            // Gordon has granted anything shouldn't be treated as an error state.
            logger.error("default launch-at-login registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
