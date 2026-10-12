import Foundation

/// Everything one stamp needs to carry between launches.
struct TelemetryState: Codable, Sendable, Equatable {
    var scan: TranscriptScanState?
    var observed: ObservedState?
    /// When counting last (re)started, until a stamp has written `bar.tracking.started` for it.
    var trackingStartPending: Date?
}

/// What a stamp did, for the app to log. Failures are collected rather than thrown so one
/// broken part (a transcript that vanished, a sink folder that's read-only) never stops the
/// rest of the stamp from being written.
public struct TelemetryStampReport: Sendable {
    public var metricCount = 0
    public var eventNames: [String] = []
    public var problems: [String] = []
}

/// Owns telemetry's persisted state and turns the app's latest data into one stamp written
/// to every sink. An actor so a slow transcript scan runs off the main thread and two
/// stamps can never interleave.
public actor TelemetryRecorder {
    private let stateURL: URL
    private let scanner: TranscriptTokenScanner
    private let resource: OTLP.Resource
    private let scope: OTLP.Scope
    private var state: TelemetryState?

    public init(
        stateURL: URL,
        scanner: TranscriptTokenScanner = TranscriptTokenScanner(),
        resource: OTLP.Resource,
        scope: OTLP.Scope
    ) {
        self.stateURL = stateURL
        self.scanner = scanner
        self.resource = resource
        self.scope = scope
    }

    public func stamp(
        usage: UsageResponse?,
        offers: AccountOffers,
        sinks: [any TelemetrySink],
        retentionDays: Int?,
        intervalMinutes: Int,
        now: Date
    ) -> TelemetryStampReport {
        var report = TelemetryStampReport()
        var state = loadState(report: &report)

        // Tokens: the first stamp after opting in only sets the starting line.
        do {
            if var scan = state.scan {
                for failure in try scanner.scan(&scan, now: now) {
                    report.problems.append("transcript \(failure.file): \(failure.message)")
                }
                state.scan = scan
            } else {
                state.scan = try scanner.baseline(now: now)
                state.trackingStartPending = now
            }
        } catch {
            report.problems.append("transcript scan failed: \(error.localizedDescription)")
        }

        let observed = TelemetryStamp.observe(usage: usage, offers: offers, previous: state.observed)
        var events = TelemetryStamp.events(previous: state.observed, current: observed, now: now)
        if let started = state.trackingStartPending {
            events.insert(TelemetryStamp.trackingStarted(now: started, intervalMinutes: intervalMinutes), at: 0)
        }
        // Offers that couldn't be fetched this time fall back to the last-known values, so
        // their gauges keep a continuous line instead of gapping on a transient failure.
        let metrics = TelemetryStamp.metrics(usage: usage, offers: observed.offers, tokens: state.scan, now: now)
        report.metricCount = metrics.count
        report.eventNames = events.map(\.eventName)

        let metricsRequest = OTLP.MetricsRequest(resource: resource, scope: scope, metrics: metrics)
        let logsRequest = OTLP.LogsRequest(resource: resource, scope: scope, logRecords: events)
        var exportFailed = false
        for sink in sinks {
            do {
                if !metrics.isEmpty { try sink.export(metrics: metricsRequest, at: now) }
                try sink.export(logs: logsRequest, at: now)
            } catch {
                exportFailed = true
                report.problems.append("sink \(type(of: sink)): \(error.localizedDescription)")
                continue
            }
            do {
                if let retentionDays { try sink.prune(retentionDays: retentionDays, now: now) }
            } catch {
                report.problems.append("sink \(type(of: sink)) prune: \(error.localizedDescription)")
            }
        }
        // Events are diffs against the last observation, so advancing it after a failed write
        // would lose them for good; holding it back re-emits them on the next stamp. Token
        // totals are cumulative and lose nothing either way, so the scan still advances.
        // With one sink this is exact; a second sink would need its own pending state.
        if exportFailed {
            report.eventNames = []
        } else {
            state.observed = observed
            state.trackingStartPending = nil
        }

        self.state = state
        do {
            try save(state)
        } catch {
            report.problems.append("state save failed: \(error.localizedDescription)")
        }
        return report
    }

    /// Sets the token baseline now if there isn't one yet, so counting starts at opt-in
    /// rather than at the first stamp. Returns problems to log; a failure here just leaves
    /// the first stamp to take the baseline instead.
    public func startCounting(now: Date) -> [String] {
        var report = TelemetryStampReport()
        var state = loadState(report: &report)
        guard state.scan == nil else { return report.problems }
        do {
            state.scan = try scanner.baseline(now: now)
            state.trackingStartPending = now
        } catch {
            report.problems.append("transcript baseline failed: \(error.localizedDescription)")
            return report.problems
        }
        self.state = state
        do {
            try save(state)
        } catch {
            report.problems.append("state save failed: \(error.localizedDescription)")
        }
        return report.problems
    }

    /// Forgets everything: the next stamp starts a fresh baseline. Called when telemetry is
    /// switched off, so switching it back on doesn't count the tokens used while it was off
    /// and the counters restart with a new start time, which OTLP reads as a counter reset.
    public func reset() throws {
        state = nil
        if FileManager.default.fileExists(atPath: stateURL.path) {
            try FileManager.default.removeItem(at: stateURL)
        }
    }

    private func loadState(report: inout TelemetryStampReport) -> TelemetryState {
        if let state { return state }
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return TelemetryState() }
        do {
            let data = try Data(contentsOf: stateURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode(TelemetryState.self, from: data)
        } catch {
            // Starting over costs one baseline; refusing to stamp would cost all of it.
            report.problems.append("state unreadable, starting a new baseline: \(error.localizedDescription)")
            return TelemetryState()
        }
    }

    private func save(_ state: TelemetryState) throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }
}
