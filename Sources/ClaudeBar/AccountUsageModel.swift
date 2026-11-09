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
    /// Self-contained sign-in is missing or was rejected; only signing in again fixes it.
    case signedOut
}

/// One account's usage: its own credentials, its own last response, its own errors.
@MainActor
@Observable
final class AccountUsageModel: Identifiable {
    private(set) var account: ClaudeAccount
    private(set) var limits: [UsageLimit] = []
    /// The whole last successful response, for telemetry, which also wants `extraUsage`.
    private(set) var lastResponse: UsageResponse?
    /// The credential source `lastResponse` was requested with, so telemetry never pairs one
    /// account's usage with another's offers after a switch.
    private(set) var lastResponseSource: CredentialSource?
    private(set) var lastUpdated: Date?
    private(set) var authState: AuthState = .ok
    private(set) var lastError: String?
    var isRefreshing: Bool { inFlight > 0 }

    /// Goes up whenever the person behind the account changes (the credential source, or the
    /// email once it was known). Async work captures it when it starts and drops its result
    /// if it moved, so a slow request can never land under someone else's name.
    private(set) var generation = 0
    private var inFlight = 0
    @ObservationIgnored private var refreshingGeneration: Int?
    @ObservationIgnored private var detector: IdentityChangeDetector
    /// The identity of our own sign-in, which labels the account while the source is
    /// self-contained; the folder's Claude Code profile can be someone else.
    @ObservationIgnored private var selfContainedIdentity: ProfileIdentity?

    /// Fixed for the model's life: discovery matches models to accounts by id.
    let id: String

    private var service: UsageService
    private var resolver: SelfContainedIdentityResolver
    private let logger = Logger(subsystem: "com.gordonbeeming.ClaudeBar", category: "UsageViewModel")

    // Celebrations: compare each poll's limits against the last to spot resets and the
    // over-pace crossing. Kept out of `@Observable` tracking (plain refs, not observed
    // state) — nothing in the UI renders from them.
    @ObservationIgnored private var previousSnapshots: [String: LimitSnapshot] = [:]
    @ObservationIgnored private var hasSeededCelebrations = false
    @ObservationIgnored weak var settings: AppSettings? {
        // The model can be built before settings exist (assuming the Claude Code source); once
        // they do, the label for the real source is applied at once.
        didSet { syncIdentity() }
    }
    /// What discovery last said about the folder (the Claude Code profile's label). The label
    /// shown is derived from this and the current source, never carried over from another source.
    @ObservationIgnored private var profileAccount: ClaudeAccount

    init(account: ClaudeAccount, settings: AppSettings?) {
        self.id = account.id
        let source = settings?.credentialSource(for: account.id) ?? .claudeCode
        // A self-contained account is labelled by its own sign-in, never by the folder's Claude
        // Code profile, so it starts unlabelled until that identity is known.
        self.profileAccount = account
        self.account = source == .selfContained ? account.withIdentity(email: nil, organization: nil) : account
        self.settings = settings
        let service = UsageService(account: account)
        self.service = service
        self.resolver = SelfContainedIdentityResolver(account: account, service: service)
        self.detector = IdentityChangeDetector(
            source: source.rawValue,
            email: source == .selfContained ? nil : account.email,
            organization: source == .selfContained ? nil : account.organization,
            revision: SelfContainedCredentialStore.revision(for: account)
        )
    }

    /// Takes a fresh discovery result for the same account id. Credentials follow the config
    /// folder, so the service is rebuilt only when that moved.
    func update(account updated: ClaudeAccount) {
        if updated.configDir != account.configDir {
            service = UsageService(account: updated)
            resolver = SelfContainedIdentityResolver(account: updated, service: service)
            selfContainedIdentity = nil
            bumpGeneration()
        }
        profileAccount = updated
        syncIdentity()
    }

    /// The label the current source calls for: our own sign-in's identity when self-contained
    /// (nothing until it is known), the folder's Claude Code profile otherwise. Applied before
    /// anything else reads the account, so a source change never keeps the old source's name.
    private func applyLabel() {
        if credentialSource != .selfContained { selfContainedIdentity = nil }
        let wanted = credentialSource == .selfContained
            ? profileAccount.withIdentity(email: selfContainedIdentity?.email, organization: selfContainedIdentity?.organization)
            : profileAccount
        if wanted != account { account = wanted }
    }

    /// Looks up who our own sign-in belongs to. Unknown (no sign-in, or the lookup failed) keeps
    /// the current label: a network blip must not wipe the menu, and a replaced sign-in shows
    /// up as a different identity.
    func refreshSelfContainedIdentity() async {
        guard credentialSource == .selfContained else { return }
        let started = generation
        let identity = await resolver.identity()
        syncIdentity()
        guard let identity, started == generation, credentialSource == .selfContained else { return }
        selfContainedIdentity = identity
        syncIdentity()
    }

    /// Notices a change of source or email and, unless it is only an unknown email becoming
    /// known for the same sign-in, starts a new generation with nothing carried over.
    func syncIdentity() {
        var replaced = false
        let revision = SelfContainedCredentialStore.revision(for: account)
        if detector.noteRevision(revision), credentialSource == .selfContained {
            // The sign-in was removed or replaced. Whoever it was before is no longer who this
            // is, whether or not the new one's identity can be looked up.
            selfContainedIdentity = nil
            // Treated as a different identity even if the label below reads as unchanged.
            detector.markReplaced()
            replaced = true
        }
        applyLabel()
        if detector.observe(source: credentialSource.rawValue, email: account.email, organization: account.organization) == .replaced {
            replaced = true
        }
        if replaced { bumpGeneration() }
    }

    private func bumpGeneration() {
        generation += 1
        limits = []
        lastResponse = nil
        lastResponseSource = nil
        lastUpdated = nil
        authState = .ok
        lastError = nil
        previousSnapshots = [:]
        hasSeededCelebrations = false
    }

    var credentialSource: CredentialSource {
        settings?.credentialSource(for: account.id) ?? .claudeCode
    }

    /// Never blocks the UI: all Keychain/network work happens inside the `UsageService`
    /// actor, and the menu keeps rendering whatever `limits` already holds while this runs.
    /// Returns the celebrations this poll earned rather than playing them, so the caller can
    /// play one effect when several accounts reset in the same tick.
    @discardableResult
    func refresh() async -> Set<ReactionChoice> {
        let first = await performRefresh()
        guard first.dropped else { return first.reactions }
        // The answer was about a sign-in that has since gone (a 401 clears it, which moves the
        // generation). Ask again for the current one, so the menu says "signed out" rather than
        // sitting on "Loading usage…".
        return await performRefresh().reactions
    }

    private func performRefresh() async -> (reactions: Set<ReactionChoice>, dropped: Bool) {
        syncIdentity()
        let started = generation
        guard refreshingGeneration != started else { return ([], false) }
        refreshingGeneration = started
        inFlight += 1
        defer {
            inFlight -= 1
            if refreshingGeneration == started { refreshingGeneration = nil }
        }

        do {
            let source = credentialSource
            let response = try await service.fetch(preferSelfContained: source == .selfContained)
            // The person behind this account changed while the request was out: the answer is
            // about someone else.
            syncIdentity()
            guard started == generation else {
                logger.notice("dropped a usage response for \(self.account.id, privacy: .public): the account changed meanwhile")
                return ([], true)
            }
            limits = response.limits
            lastResponse = response
            lastResponseSource = source
            lastUpdated = Date()
            authState = .ok
            lastError = nil
            return (celebrations(for: response.limits, now: Date()), false)
        } catch {
            syncIdentity()
            guard started == generation else { return ([], true) }
            switch error {
            case UsageClient.UsageError.unauthorized:
                authState = .tokenExpired
                lastError = nil
            case UsageClient.UsageError.noToken:
                authState = .noToken
                lastError = nil
            case UsageClient.UsageError.signedOut:
                authState = .signedOut
                lastError = nil
            default:
                logger.error("usage refresh failed for \(self.account.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                lastError = "Couldn't refresh: \(error.localizedDescription)"
            }
        }
        return ([], false)
    }

    func isStale(threshold: TimeInterval) -> Bool {
        lastUpdated.map { Date().timeIntervalSince($0) > threshold } ?? true
    }

    /// Guest passes and promotional credit, fetched with the same token choice as usage.
    func fetchAccountOffers() async -> AccountOffers {
        await service.fetchAccountOffers(preferSelfContained: credentialSource == .selfContained)
    }

    private func celebrations(for limits: [UsageLimit], now: Date) -> Set<ReactionChoice> {
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
            return []
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
                usage dropped \(drop, privacy: .public) points for \(limit.id, privacy: .public) \
                (account \(self.account.id, privacy: .public)) — \(prev.percent, privacy: .public)% → \
                \(limit.percent, privacy: .public)% — \
                \(countedAsReset ? "counted as reset" : "below reset threshold", privacy: .public)
                """)
        }

        guard let settings, settings.celebrationsEnabled else { return [] }

        let events = detectCelebrationEvents(previous: previousSnapshots, current: limits, now: now)
        let reactions = Set(
            events
                .filter { settings.celebrationEnabled(for: $0) }
                .map { settings.reaction(for: $0) }
        )
        if !reactions.isEmpty {
            let fired = events.map(\.rawValue).sorted().joined(separator: ",")
            logger.notice("celebrations earned by \(self.account.id, privacy: .public): \(fired, privacy: .public)")
        }
        return reactions
    }
}
