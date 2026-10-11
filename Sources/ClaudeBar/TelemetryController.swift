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

    private let recorder: TelemetryRecorder
    private let logger = Logger(subsystem: "com.gordonbeeming.ClaudeBar", category: "Telemetry")
    private weak var model: UsageViewModel?
    private weak var settings: AppSettings?
    private var loopTask: Task<Void, Never>?
    /// The opt-out reset. A loop started afterwards waits for it, so a quick off-then-on can't
    /// have the old reset delete the new baseline.
    private var resetTask: Task<Void, Never>?
    private var running: (enabled: Bool, interval: TimeInterval)?
    private var lastOffersFetch: (at: Date, source: CredentialSource)?
    private var lastOffers = AccountOffers()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        recorder = TelemetryRecorder(
            stateURL: support.appending(path: "ClaudeBar/telemetry-state.json"),
            resource: OTLP.Resource(attributes: [
                .init("service.name", .string("claudebar")),
                .init("service.version", .string(version)),
                .init("host.name", .string(ProcessInfo.processInfo.hostName)),
                .init("os.type", .string("darwin")),
            ]),
            scope: OTLP.Scope(name: "com.gordonbeeming.ClaudeBar.telemetry", version: version)
        )
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
            lastOffers = AccountOffers()
            lastOffersFetch = nil
            let recorder = recorder
            let logger = logger
            let pendingReset = resetTask
            resetTask = Task {
                // Cancelling doesn't interrupt a stamp already running on the recorder, so
                // let it land first; otherwise it could write state after the reset.
                await previousLoop?.value
                await pendingReset?.value
                do {
                    try await recorder.reset()
                    logger.notice("telemetry off: cleared its state")
                } catch {
                    logger.error("telemetry state reset failed: \(error.localizedDescription, privacy: .public)")
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
        while model?.lastUpdated == nil, ContinuousClock.now < deadline, !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
        }
    }

    private func startCounting() async {
        for problem in await recorder.startCounting(now: Date()) {
            logger.error("telemetry: \(problem, privacy: .private)")
        }
    }

    private func stamp() async {
        guard let model, let settings, settings.telemetryEnabled else { return }
        let now = Date()
        // Offers belong to whichever account the source signs in as, so a source switch
        // refetches straight away rather than pairing new usage with old offers.
        let source = settings.credentialSource
        let offersStale = lastOffersFetch.map {
            $0.source != source || now.timeIntervalSince($0.at) >= Self.offersRefreshInterval
        } ?? true
        if offersStale {
            lastOffers = await model.fetchAccountOffers()
            lastOffersFetch = (now, source)
        }
        // Read everything else after the last suspension point: switching telemetry off, or
        // changing the folder, retention or source while the offers fetch was in flight must
        // not write to the old place or mix two accounts.
        let config = settings.telemetryConfig
        guard !Task.isCancelled, config.enabled, settings.credentialSource == source else { return }

        let usage: UsageResponse? = if let updated = model.lastUpdated,
            now.timeIntervalSince(updated) <= Self.usageFreshness,
            model.lastResponseSource == source {
            model.lastResponse
        } else {
            nil
        }
        if usage == nil {
            logger.notice("telemetry stamp without usage: last poll is missing, stale, or from another credential source")
        }

        let report = await recorder.stamp(
            usage: usage,
            offers: lastOffers,
            sinks: makeSinks(config.sinks),
            retentionDays: config.retentionDays,
            now: now
        )
        logger.notice("""
            telemetry stamp: \(report.metricCount, privacy: .public) metrics, \
            events [\(report.eventNames.joined(separator: ","), privacy: .public)]
            """)
        // Problems can name transcript paths, which carry project names.
        for problem in report.problems {
            logger.error("telemetry: \(problem, privacy: .private)")
        }
    }
}
