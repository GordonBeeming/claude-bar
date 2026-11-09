import ClaudeBarCore
import Foundation
import Observation
import os

/// Runs the telemetry stamp loop while the user has it switched on. Reuses the usage the
/// view model already polls every minute, so stamping never adds a usage-API call of its own.
@MainActor
final class TelemetryController {
    /// Usage older than this is left out of a stamp rather than written with a misleading
    /// timestamp (the poll has been failing, e.g. offline).
    private static let usageFreshness: TimeInterval = 300
    /// Floor between account-offer fetches, however short the stamp interval is.
    private static let offersRefreshInterval: TimeInterval = 300
    /// How long the first stamp after launch waits for the first usage poll to land.
    private static let firstUsageWait: Duration = .seconds(30)

    /// What one account needs to stamp: its recorder, and the offers last fetched for it. Built
    /// for one account generation, credential source and email; any change replaces it, since
    /// the recorder's resource carries the email and the offers are that person's.
    private final class Tracker {
        let recorder: TelemetryRecorder
        let generation: Int
        let source: CredentialSource
        let email: String?
        let organization: String?
        /// Whether the recorder's state has been checked against this tracker's owner.
        var adopted = false
        /// Set when this tracker replaced one from an earlier generation: a different sign-in
        /// can look like the same owner, so its predecessor's observations must go regardless.
        var clearObservations = false
        var lastOffersFetch: (at: Date, source: CredentialSource)?
        var lastOffers = AccountOffers()

        init(recorder: TelemetryRecorder, generation: Int, source: CredentialSource, email: String?, organization: String?) {
            self.recorder = recorder
            self.generation = generation
            self.source = source
            self.email = email
            self.organization = organization
        }

        /// The organisation is part of it: the same email on another organisation has other
        /// limits and offers.
        var owner: String { "\(source.rawValue)|\(email ?? "")|\(organization ?? "")" }
    }

    private let logger = Logger(subsystem: "com.gordonbeeming.ClaudeBar", category: "Telemetry")
    private let stateDirectory: URL
    private let version: String
    private var trackers: [String: Tracker] = [:]
    private weak var model: UsageViewModel?
    private weak var settings: AppSettings?
    private var loopTask: Task<Void, Never>?
    /// The opt-out reset. A loop started afterwards waits for it, so a quick off-then-on can't
    /// have the old reset delete the new baseline.
    private var resetTask: Task<Void, Never>?
    private var running: (enabled: Bool, interval: TimeInterval)?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        stateDirectory = support.appending(path: "ClaudeBar", directoryHint: .isDirectory)
        version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// `isNew` is true when the account had no tracker at all.
    private func tracker(for model: AccountUsageModel) -> (tracker: Tracker, isNew: Bool) {
        model.syncIdentity()
        let account = model.account
        let source = model.credentialSource
        let existing = trackers[account.id]
        if let existing, existing.generation == model.generation, existing.source == source,
           existing.email == account.email, existing.organization == account.organization {
            return (existing, false)
        }
        let recorder = TelemetryRecorder(
            stateURL: stateDirectory.appending(path: account.telemetryStateFileName),
            scanner: TranscriptTokenScanner(root: account.transcriptsRoot),
            resource: account.telemetryResource(version: version, hostName: ProcessInfo.processInfo.hostName),
            scope: OTLP.Scope(name: "com.gordonbeeming.ClaudeBar.telemetry", version: version)
        )
        let created = Tracker(
            recorder: recorder, generation: model.generation, source: source,
            email: account.email, organization: account.organization
        )
        // An email going from unknown to known within one generation is the same sign-in being
        // labelled, so what was fetched for it still applies.
        if let existing, existing.generation == model.generation, existing.source == source {
            created.lastOffers = existing.lastOffers
            created.lastOffersFetch = existing.lastOffersFetch
        }
        created.clearObservations = existing.map { $0.generation != model.generation } ?? false
        trackers[account.id] = created
        return (created, existing == nil)
    }

    /// True while `tracker` is still the one for `account` as it was when the stamp began. Every
    /// await in a stamp is followed by this, so nothing is written under another person's name.
    private func isCurrent(_ tracker: Tracker, for account: AccountUsageModel, generation: Int) -> Bool {
        account.syncIdentity()
        return !Task.isCancelled
            && trackers[account.id] === tracker
            && account.generation == generation
            && account.credentialSource == tracker.source
            && account.account.email == tracker.email
            && account.account.organization == tracker.organization
    }

    /// Idempotent, like `UsageViewModel.startPolling()`: the label's `.onAppear` can fire
    /// more than once.
    func attach(model: UsageViewModel, settings: AppSettings) {
        guard self.model == nil else { return }
        self.model = model
        self.settings = settings
        applySettings()
    }

    private func applySettings() {
        guard let settings else { return }
        let config = withObservationTracking {
            settings.telemetryConfig
        } onChange: { [weak self] in
            Task { @MainActor in self?.applySettings() }
        }

        // Folder and retention are read fresh on every stamp, so only switching on/off or a
        // new interval restarts the loop; changing retention doesn't fire stamps.
        let wanted = (enabled: config.enabled, interval: config.intervalSeconds)
        if let running, running == wanted { return }
        running = wanted
        let previousLoop = loopTask
        previousLoop?.cancel()
        loopTask = nil

        guard config.enabled else {
            // Every tracker held, and every state file on disk, goes: an account that is no
            // longer discovered would otherwise keep a cursor that counts the time tracking
            // was off once it came back.
            let recorders = trackers.values.map(\.recorder)
            trackers.removeAll()
            let directory = stateDirectory
            let logger = logger
            let pendingReset = resetTask
            resetTask = Task {
                // Cancelling doesn't interrupt a stamp already running on a recorder, so
                // let it land first; otherwise it could write state after the reset.
                await previousLoop?.value
                await pendingReset?.value
                for recorder in recorders {
                    do {
                        try await recorder.reset()
                    } catch {
                        logger.error("telemetry state reset failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
                do {
                    let removed = try TelemetryRecorder.removeAllStateFiles(in: directory)
                    logger.notice("telemetry off: cleared state for \(removed.count, privacy: .public) account file(s)")
                } catch {
                    logger.error("telemetry state cleanup failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            return
        }

        let pendingReset = resetTask
        loopTask = Task { [weak self] in
            await pendingReset?.value
            // Tokens count from the moment of opting in, not from the first full stamp,
            // which can be up to `firstUsageWait` later.
            await self?.startCounting()
            await self?.waitForFirstUsage()
            while !Task.isCancelled {
                await self?.stamp()
                do {
                    try await Task.sleep(for: .seconds(config.intervalSeconds))
                } catch {
                    return // cancelled: settings changed or telemetry was switched off
                }
            }
        }
    }

    private func waitForFirstUsage() async {
        let deadline = ContinuousClock.now + Self.firstUsageWait
        while model?.accounts.contains(where: { $0.lastUpdated == nil }) ?? false,
              ContinuousClock.now < deadline, !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
        }
    }

    private func startCounting() async {
        for account in model?.accounts ?? [] {
            // Opting out cancels this loop and clears the trackers; one created afterwards would
            // write a baseline the opt-out never clears.
            guard !Task.isCancelled, settings?.telemetryEnabled == true else { return }
            let (tracker, isNew) = tracker(for: account)
            if isNew { await startCounting(tracker) }
        }
    }

    private func startCounting(_ tracker: Tracker) async {
        for problem in await tracker.recorder.startCounting(now: Date()) {
            logger.error("telemetry: \(problem, privacy: .private)")
        }
    }

    /// Stamps every account in turn. One account failing to stamp never holds up the others.
    private func stamp() async {
        guard let model, let settings, settings.telemetryEnabled else { return }
        for account in model.accounts {
            guard !Task.isCancelled else { return }
            await stamp(account, settings: settings)
        }
    }

    private func stamp(_ account: AccountUsageModel, settings: AppSettings) async {
        guard settings.telemetryEnabled else { return }
        let (tracker, isNew) = tracker(for: account)
        let generation = account.generation
        if isNew { await startCounting(tracker) }
        if !tracker.adopted {
            // Observations on disk may belong to someone else (the sign-in changed while the app
            // was closed); the recorder clears them unless the owner matches.
            for problem in await tracker.recorder.adopt(owner: tracker.owner, forceClear: tracker.clearObservations) {
                logger.error("telemetry: \(problem, privacy: .private)")
            }
            tracker.adopted = true
        }
        guard isCurrent(tracker, for: account, generation: generation) else { return }

        let now = Date()
        // Offers belong to whichever sign-in the source uses, so a source switch refetches
        // straight away rather than pairing new usage with old offers.
        let source = tracker.source
        let offersStale = tracker.lastOffersFetch.map {
            $0.source != source || now.timeIntervalSince($0.at) >= Self.offersRefreshInterval
        } ?? true
        if offersStale {
            let offers = await account.fetchAccountOffers()
            guard isCurrent(tracker, for: account, generation: generation) else { return }
            tracker.lastOffers = offers
            tracker.lastOffersFetch = (now, source)
        }
        // Read everything else after the last suspension point: switching telemetry off, or
        // changing the folder or retention while the offers fetch was in flight must not
        // write to the old place.
        let config = settings.telemetryConfig
        guard config.enabled else { return }

        let usage: UsageResponse? = if let updated = account.lastUpdated,
            now.timeIntervalSince(updated) <= Self.usageFreshness,
            account.lastResponseSource == source {
            account.lastResponse
        } else {
            nil
        }
        if usage == nil {
            logger.notice("telemetry stamp without usage for \(account.id, privacy: .public): last poll is missing, stale, or from another credential source")
        }

        let report = await tracker.recorder.stamp(
            usage: usage,
            offers: tracker.lastOffers,
            sinks: makeSinks(config.sinks, serviceName: account.account.telemetryFileServiceName),
            retentionDays: config.retentionDays,
            intervalMinutes: Int((config.intervalSeconds / 60).rounded()),
            now: now
        )
        logger.notice("""
            telemetry stamp for \(account.id, privacy: .public): \(report.metricCount, privacy: .public) metrics, \
            events [\(report.eventNames.joined(separator: ","), privacy: .public)]
            """)
        // Problems can name transcript paths, which carry project names.
        for problem in report.problems {
            logger.error("telemetry: \(problem, privacy: .private)")
        }
    }
}
