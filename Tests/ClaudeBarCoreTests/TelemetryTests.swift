import Foundation
import Testing
@testable import ClaudeBarCore

// MARK: - Helpers

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "claudebar-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func usageLine(id: String, request: String, model: String = "claude-opus-5-5", input: Int = 10, output: Int = 20, cacheRead: Int = 100, write5m: Int = 30, write1h: Int = 40) -> String {
    """
    {"type":"assistant","requestId":"\(request)","message":{"id":"\(id)","model":"\(model)","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":\(write5m + write1h),"cache_creation":{"ephemeral_5m_input_tokens":\(write5m),"ephemeral_1h_input_tokens":\(write1h)},"server_tool_use":{"web_search_requests":1,"web_fetch_requests":0}}}}
    """
}

private func append(_ text: String, to url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
}

private func limit(_ kind: String, group: String, percent: Double, severity: Severity = .normal, resetsAt: Date? = nil, model: String? = nil) -> UsageLimit {
    UsageLimit(
        kind: kind,
        group: group,
        percent: percent,
        severity: severity,
        resetsAt: resetsAt,
        scope: model.map { LimitScope(model: .init(id: nil, displayName: $0)) }
    )
}

// MARK: - OTLP encoding

struct OTLPEncodingTests {
    private let resource = OTLP.Resource(attributes: [.init("service.name", .string("claudebar"))])
    private let scope = OTLP.Scope(name: "test", version: "1")

    @Test func gaugeAndSumFollowOTLPJSONMapping() throws {
        let time = Date(timeIntervalSince1970: 1_790_000_000.123)
        let request = OTLP.MetricsRequest(resource: resource, scope: scope, metrics: [
            .init(name: "g", unit: "%", description: "d", kind: .gauge, dataPoints: [
                .init(attributes: [.init("a", .bool(true))], time: time, value: .double(12.5)),
            ]),
            .init(name: "s", unit: "{token}", description: "d", kind: .cumulativeSum, dataPoints: [
                .init(attributes: [.init("n", .int(7))], startTime: Date(timeIntervalSince1970: 1_789_000_000), time: time, value: .int(42)),
            ]),
        ])
        let line = try OTLP.encodeLine(request)
        #expect(line.last == 0x0A)
        #expect(line.dropLast().contains(0x0A) == false)

        let root = try jsonObject(line)
        let resourceMetrics = try #require(root["resourceMetrics"] as? [[String: Any]])
        let scopeMetrics = try #require(resourceMetrics.first?["scopeMetrics"] as? [[String: Any]])
        let metrics = try #require(scopeMetrics.first?["metrics"] as? [[String: Any]])

        let gaugePoint = try #require(((metrics[0]["gauge"] as? [String: Any])?["dataPoints"] as? [[String: Any]])?.first)
        #expect(gaugePoint["timeUnixNano"] as? String == "1790000000123000000")
        #expect(gaugePoint["asDouble"] as? Double == 12.5)
        #expect(gaugePoint["startTimeUnixNano"] == nil)
        let gaugeAttribute = try #require((gaugePoint["attributes"] as? [[String: Any]])?.first)
        #expect((gaugeAttribute["value"] as? [String: Any])?["boolValue"] as? Bool == true)

        let sum = try #require(metrics[1]["sum"] as? [String: Any])
        #expect(sum["aggregationTemporality"] as? Int == 2)
        #expect(sum["isMonotonic"] as? Bool == true)
        let sumPoint = try #require((sum["dataPoints"] as? [[String: Any]])?.first)
        // int64 values travel as strings in OTLP JSON.
        #expect(sumPoint["asInt"] as? String == "42")
        #expect(sumPoint["startTimeUnixNano"] as? String == "1789000000000000000")
        let sumAttribute = try #require((sumPoint["attributes"] as? [[String: Any]])?.first)
        #expect((sumAttribute["value"] as? [String: Any])?["intValue"] as? String == "7")
    }

    @Test func logRecordCarriesEventNameAsAttribute() throws {
        let request = OTLP.LogsRequest(resource: resource, scope: scope, logRecords: [
            .init(time: Date(timeIntervalSince1970: 1), eventName: "limit.reset", body: "Session reset", attributes: [.init("percent", .double(0))]),
        ])
        let root = try jsonObject(OTLP.encodeLine(request))
        let resourceLogs = try #require(root["resourceLogs"] as? [[String: Any]])
        let scopeLogs = try #require(resourceLogs.first?["scopeLogs"] as? [[String: Any]])
        let record = try #require((scopeLogs.first?["logRecords"] as? [[String: Any]])?.first)
        #expect(record["severityNumber"] as? Int == 9)
        #expect((record["body"] as? [String: Any])?["stringValue"] as? String == "Session reset")
        let attributes = try #require(record["attributes"] as? [[String: Any]])
        #expect(attributes.first?["key"] as? String == "event.name")
        #expect((attributes.first?["value"] as? [String: Any])?["stringValue"] as? String == "limit.reset")
    }
}

// MARK: - Transcript scanning

struct TranscriptTokenScannerTests {
    @Test func baselineSkipsExistingHistoryAndCountsOnlyNewLines() throws {
        let root = try temporaryDirectory()
        let project = root.appending(path: "-Users-me-repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appending(path: "session.jsonl")
        try append(usageLine(id: "old", request: "r0") + "\n", to: file)

        let scanner = TranscriptTokenScanner(root: root)
        var state = try scanner.baseline(now: Date())
        #expect(state.totals.isEmpty)

        try append(usageLine(id: "m1", request: "r1") + "\n", to: file)
        try scanner.scan(&state, now: Date())

        let totals = try #require(state.totals["claude-opus-5-5"])
        #expect(totals.input == 10)
        #expect(totals.output == 20)
        #expect(totals.cacheRead == 100)
        #expect(totals.cacheWrite5m == 30)
        #expect(totals.cacheWrite1h == 40)
        #expect(totals.messages == 1)
        #expect(totals.webSearchRequests == 1)
    }

    @Test func repeatedContentBlockLinesCountOnce() throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "s.jsonl")
        let scanner = TranscriptTokenScanner(root: root)
        var state = try scanner.baseline(now: Date())

        // One message split over three content blocks, each line repeating the same usage.
        let line = usageLine(id: "m1", request: "r1")
        try append([line, line, line, usageLine(id: "m2", request: "r2")].joined(separator: "\n") + "\n", to: file)
        try scanner.scan(&state, now: Date())

        #expect(state.totals["claude-opus-5-5"]?.messages == 2)
        #expect(state.totals["claude-opus-5-5"]?.output == 40)
    }

    @Test func partialTrailingLineWaitsUntilComplete() throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "s.jsonl")
        let scanner = TranscriptTokenScanner(root: root)
        var state = try scanner.baseline(now: Date())

        let line = usageLine(id: "m1", request: "r1")
        let split = line.index(line.startIndex, offsetBy: 40)
        try append(String(line[..<split]), to: file)
        try scanner.scan(&state, now: Date())
        #expect(state.totals.isEmpty)

        try append(String(line[split...]) + "\n", to: file)
        try scanner.scan(&state, now: Date())
        #expect(state.totals["claude-opus-5-5"]?.messages == 1)
    }

    @Test func fileCreatedAfterBaselineIsReadFromTheStart() throws {
        let root = try temporaryDirectory()
        let scanner = TranscriptTokenScanner(root: root)
        var state = try scanner.baseline(now: Date())

        try append(usageLine(id: "m1", request: "r1", model: "claude-sonnet-5-5") + "\n", to: root.appending(path: "new.jsonl"))
        try scanner.scan(&state, now: Date())
        #expect(state.totals["claude-sonnet-5-5"]?.messages == 1)
    }

    @Test func rewrittenShorterFileIsRebaselinedNotReplayed() throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "s.jsonl")
        let scanner = TranscriptTokenScanner(root: root)
        var state = try scanner.baseline(now: Date())
        try append(usageLine(id: "m1", request: "r1") + "\n" + usageLine(id: "m2", request: "r2") + "\n", to: file)
        try scanner.scan(&state, now: Date())
        #expect(state.totals["claude-opus-5-5"]?.messages == 2)

        // A compaction keeps m1, already counted; replaying it would count it twice.
        try FileManager.default.removeItem(at: file)
        try append(usageLine(id: "m1", request: "r1") + "\n", to: file)
        try scanner.scan(&state, now: Date())
        #expect(state.totals["claude-opus-5-5"]?.messages == 2)

        try append(usageLine(id: "m3", request: "r3") + "\n", to: file)
        try scanner.scan(&state, now: Date())
        #expect(state.totals["claude-opus-5-5"]?.messages == 3)
    }

    @Test func syntheticAndUsagelessLinesAreIgnored() {
        #expect(TranscriptTokenScanner.parse(line: Data(usageLine(id: "x", request: "y", model: "<synthetic>").utf8)) == nil)
        #expect(TranscriptTokenScanner.parse(line: Data(#"{"type":"user","message":{"content":"hi"}}"#.utf8)) == nil)
        #expect(TranscriptTokenScanner.parse(line: Data("not json \"output_tokens\"".utf8)) == nil)
    }

    @Test func cacheWriteWithoutBreakdownCountsAsFiveMinute() throws {
        let line = #"{"requestId":"r","message":{"id":"m","model":"claude-haiku-5-5","usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":50}}}"#
        let usage = try #require(TranscriptTokenScanner.parse(line: Data(line.utf8)))
        #expect(usage.cacheWrite5m == 50)
        #expect(usage.cacheWrite1h == 0)
    }
}

// MARK: - Stamp metrics and events

struct TelemetryStampTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func limitMetricsCarryIdentifyingAttributes() throws {
        let usage = UsageResponse(limits: [
            limit("session", group: "session", percent: 3, resetsAt: now.addingTimeInterval(3600)),
            limit("weekly_scoped", group: "weekly", percent: 27, model: "Fable"),
        ])
        let metrics = TelemetryStamp.metrics(usage: usage, offers: AccountOffers(), tokens: nil, now: now)
        let utilization = try #require(metrics.first { $0.name == "claude.usage.limit.utilization" })
        #expect(utilization.dataPoints.count == 2)
        let scoped = try #require(utilization.dataPoints.first { point in point.attributes.contains(.init("model.name", .string("Fable"))) })
        #expect(scoped.value == .double(27))
        #expect(scoped.attributes.contains(.init("limit.kind", .string("weekly_scoped"))))

        // Only the session limit has a reset time; the scoped one contributes no point.
        let resets = try #require(metrics.first { $0.name == "claude.usage.limit.resets_at" })
        #expect(resets.dataPoints.count == 1)
    }

    @Test func noUsageMeansNoLimitMetrics() {
        let metrics = TelemetryStamp.metrics(usage: nil, offers: AccountOffers(), tokens: nil, now: now)
        #expect(metrics.isEmpty)
    }

    @Test func firstObservationOnlySeeds() {
        let current = TelemetryStamp.observe(usage: UsageResponse(limits: [limit("session", group: "session", percent: 50)]), offers: AccountOffers(), previous: nil)
        #expect(TelemetryStamp.events(previous: nil, current: current, now: now).isEmpty)
    }

    @Test func resetAndSeverityChangesBecomeEvents() {
        let before = TelemetryStamp.observe(
            usage: UsageResponse(limits: [
                limit("session", group: "session", percent: 80, severity: .warning),
                limit("weekly_all", group: "weekly", percent: 60),
            ]),
            offers: AccountOffers(),
            previous: nil
        )
        let after = TelemetryStamp.observe(
            usage: UsageResponse(limits: [
                limit("session", group: "session", percent: 0),
                limit("weekly_all", group: "weekly", percent: 76, severity: .warning),
            ]),
            offers: AccountOffers(),
            previous: before
        )
        let names = TelemetryStamp.events(previous: before, current: after, now: now).map(\.eventName)
        #expect(names.filter { $0 == "limit.reset" }.count == 1)
        #expect(names.filter { $0 == "limit.severity_changed" }.count == 2)
    }

    @Test func newScopedLimitAppears() {
        let before = TelemetryStamp.observe(usage: UsageResponse(limits: [limit("session", group: "session", percent: 1)]), offers: AccountOffers(), previous: nil)
        let after = TelemetryStamp.observe(
            usage: UsageResponse(limits: [limit("session", group: "session", percent: 1), limit("weekly_scoped", group: "weekly", percent: 0, model: "Fable")]),
            offers: AccountOffers(),
            previous: before
        )
        #expect(TelemetryStamp.events(previous: before, current: after, now: now).map(\.eventName) == ["limit.appeared"])
    }

    @Test func indistinguishableLimitsNeverFireEvents() {
        // Two scoped limits with no model identity share a key; list order swapping must not
        // read as one of them resetting or changing severity.
        let before = TelemetryStamp.observe(
            usage: UsageResponse(limits: [
                limit("weekly_scoped", group: "weekly", percent: 90, severity: .critical),
                limit("weekly_scoped", group: "weekly", percent: 5),
            ]),
            offers: AccountOffers(),
            previous: nil
        )
        let after = TelemetryStamp.observe(
            usage: UsageResponse(limits: [
                limit("weekly_scoped", group: "weekly", percent: 5),
                limit("weekly_scoped", group: "weekly", percent: 90, severity: .critical),
            ]),
            offers: AccountOffers(),
            previous: before
        )
        #expect(TelemetryStamp.events(previous: before, current: after, now: now).isEmpty)

        // One of them going away leaves a single limit under that key; it isn't "appeared".
        let single = TelemetryStamp.observe(
            usage: UsageResponse(limits: [limit("weekly_scoped", group: "weekly", percent: 5)]),
            offers: AccountOffers(),
            previous: after
        )
        #expect(TelemetryStamp.events(previous: after, current: single, now: now).isEmpty)
    }

    private func passes(_ remaining: Int?, eligible: Bool = true) -> AccountOffers {
        AccountOffers(guestPasses: GuestPassStatus(campaign: "claude_code_guest_pass", eligible: eligible, remaining: remaining, limit: 3))
    }

    private func reason(_ event: OTLP.LogRecord) -> String? {
        event.attributes.first { $0.key == "inferred_reason" }.flatMap {
            if case .string(let value) = $0.value { value } else { nil }
        }
    }

    @Test func guestPassRedeemedIsUsed() throws {
        let before = TelemetryStamp.observe(usage: nil, offers: passes(3), previous: ObservedState())
        let after = TelemetryStamp.observe(usage: nil, offers: passes(2), previous: before)
        let event = try #require(TelemetryStamp.events(previous: before, current: after, now: now).first)
        #expect(event.eventName == "guest_pass.gone")
        #expect(reason(event) == "used")
    }

    @Test func guestPassesWithdrawnAreExpired() throws {
        let before = TelemetryStamp.observe(usage: nil, offers: passes(2), previous: ObservedState())
        let after = TelemetryStamp.observe(usage: nil, offers: passes(nil, eligible: false), previous: before)
        let event = try #require(TelemetryStamp.events(previous: before, current: after, now: now).first)
        #expect(event.eventName == "guest_pass.gone")
        #expect(reason(event) == "expired")
    }

    @Test func guestPassesAppear() {
        let before = TelemetryStamp.observe(usage: nil, offers: passes(nil, eligible: false), previous: ObservedState())
        let after = TelemetryStamp.observe(usage: nil, offers: passes(3), previous: before)
        #expect(TelemetryStamp.events(previous: before, current: after, now: now).map(\.eventName) == ["guest_pass.available"])
    }

    private func grant(available: Bool, granted: Bool = false) -> AccountOffers {
        AccountOffers(creditGrant: CreditGrantStatus(campaign: "feature_of_the_week", available: available, eligible: true, granted: granted, amountMinorUnits: 2000, currency: "USD"))
    }

    @Test func offersFirstSeenAfterAFailedFetchAreOnlyABaseline() {
        // The previous stamp's fetch failed, so whether these existed before is unknown.
        let current = TelemetryStamp.observe(
            usage: nil,
            offers: AccountOffers(guestPasses: passes(3).guestPasses, creditGrant: grant(available: true).creditGrant),
            previous: ObservedState()
        )
        #expect(TelemetryStamp.events(previous: ObservedState(), current: current, now: now).isEmpty)
    }

    @Test func creditGrantClaimedIsUsed() throws {
        let unclaimable = TelemetryStamp.observe(usage: nil, offers: grant(available: false), previous: ObservedState())
        let before = TelemetryStamp.observe(usage: nil, offers: grant(available: true), previous: unclaimable)
        #expect(TelemetryStamp.events(previous: unclaimable, current: before, now: now).map(\.eventName) == ["credit_grant.available"])

        let after = TelemetryStamp.observe(usage: nil, offers: grant(available: false, granted: true), previous: before)
        let event = try #require(TelemetryStamp.events(previous: before, current: after, now: now).first)
        #expect(event.eventName == "credit_grant.gone")
        #expect(reason(event) == "used")
    }

    @Test func creditGrantGoneWithUsageDropIsUsed() throws {
        let resets = now.addingTimeInterval(86_400)
        let before = TelemetryStamp.observe(usage: UsageResponse(limits: [limit("weekly_all", group: "weekly", percent: 90, resetsAt: resets)]), offers: grant(available: true), previous: ObservedState())
        let after = TelemetryStamp.observe(usage: UsageResponse(limits: [limit("weekly_all", group: "weekly", percent: 60, resetsAt: resets)]), offers: grant(available: false), previous: before)
        let event = try #require(TelemetryStamp.events(previous: before, current: after, now: now).first { $0.eventName == "credit_grant.gone" })
        #expect(reason(event) == "used")
    }

    @Test func creditGrantGoneWithSteadyUsageIsExpired() throws {
        let resets = now.addingTimeInterval(86_400)
        let before = TelemetryStamp.observe(usage: UsageResponse(limits: [limit("weekly_all", group: "weekly", percent: 50, resetsAt: resets)]), offers: grant(available: true), previous: ObservedState())
        let after = TelemetryStamp.observe(usage: UsageResponse(limits: [limit("weekly_all", group: "weekly", percent: 52, resetsAt: resets)]), offers: grant(available: false), previous: before)
        let event = try #require(TelemetryStamp.events(previous: before, current: after, now: now).first { $0.eventName == "credit_grant.gone" })
        #expect(reason(event) == "expired")
    }

    @Test func failedOfferFetchKeepsLastKnownValue() {
        let before = TelemetryStamp.observe(usage: nil, offers: passes(2), previous: ObservedState())
        let after = TelemetryStamp.observe(usage: nil, offers: AccountOffers(), previous: before)
        #expect(after.offers.guestPasses?.remaining == 2)
        #expect(TelemetryStamp.events(previous: before, current: after, now: now).isEmpty)
    }
}

// MARK: - File sink

struct FileTelemetrySinkTests {
    @Test func writesDailyFilesAndPrunesOnlyItsOwnOldOnes() throws {
        let directory = try temporaryDirectory().appending(path: "ClaudeBar Telemetry", directoryHint: .isDirectory)
        let sink = FileTelemetrySink(directory: directory)
        let now = Date()
        let request = OTLP.MetricsRequest(
            resource: .init(attributes: []),
            scope: .init(name: "t", version: "1"),
            metrics: [.init(name: "m", unit: "1", description: "", kind: .gauge, dataPoints: [.init(attributes: [], time: now, value: .int(1))])]
        )
        try sink.export(metrics: request, at: now)
        try sink.export(metrics: request, at: now)

        let todayFile = directory.appending(path: FileTelemetrySink.fileName(prefix: "metrics", on: now))
        let lines = try String(contentsOf: todayFile, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)

        let old = Calendar.current.date(byAdding: .day, value: -100, to: now) ?? now
        let oldFile = directory.appending(path: FileTelemetrySink.fileName(prefix: "logs", on: old))
        let foreign = directory.appending(path: "notes.txt")
        FileManager.default.createFile(atPath: oldFile.path, contents: Data())
        FileManager.default.createFile(atPath: foreign.path, contents: Data())

        try sink.prune(retentionDays: 90, now: now)
        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
        #expect(FileManager.default.fileExists(atPath: todayFile.path))
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    @Test func emptyLogBatchWritesNothing() throws {
        let directory = try temporaryDirectory()
        let sink = FileTelemetrySink(directory: directory)
        try sink.export(logs: .init(resource: .init(attributes: []), scope: .init(name: "t", version: "1"), logRecords: []), at: Date())
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}

// MARK: - Recorder end to end

struct TelemetryRecorderTests {
    @Test func stampsWriteMetricsTokensAndEventsThenResetStartsOver() async throws {
        let base = try temporaryDirectory()
        let transcripts = base.appending(path: "projects", directoryHint: .isDirectory)
        let output = base.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
        let transcript = transcripts.appending(path: "s.jsonl")
        try append(usageLine(id: "before", request: "r0") + "\n", to: transcript)

        let stateURL = base.appending(path: "state/telemetry-state.json")
        let recorder = TelemetryRecorder(
            stateURL: stateURL,
            scanner: TranscriptTokenScanner(root: transcripts),
            resource: .init(attributes: [.init("service.name", .string("claudebar"))]),
            scope: .init(name: "t", version: "1")
        )
        let sinks: [any TelemetrySink] = [FileTelemetrySink(directory: output)]
        let start = Date()

        let first = await recorder.stamp(
            usage: UsageResponse(limits: [limit("session", group: "session", percent: 70)]),
            offers: AccountOffers(),
            sinks: sinks, retentionDays: 90, now: start
        )
        #expect(first.problems.isEmpty)
        #expect(first.eventNames.isEmpty)
        #expect(FileManager.default.fileExists(atPath: stateURL.path))

        try append(usageLine(id: "after", request: "r1") + "\n", to: transcript)
        let second = await recorder.stamp(
            usage: UsageResponse(limits: [limit("session", group: "session", percent: 0)]),
            offers: AccountOffers(),
            sinks: sinks, retentionDays: 90, now: start.addingTimeInterval(300)
        )
        #expect(second.problems.isEmpty)
        #expect(second.eventNames == ["limit.reset"])

        let metricsFile = output.appending(path: FileTelemetrySink.fileName(prefix: "metrics", on: start))
        let lines = try String(contentsOf: metricsFile, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        // Only the message written after opting in is counted.
        let last = String(lines[1])
        #expect(last.contains("\"claude.code.tokens\""))
        #expect(last.contains("\"asInt\":\"20\""))
        #expect(!String(lines[0]).contains("claude.code.tokens"))

        try await recorder.reset()
        #expect(!FileManager.default.fileExists(atPath: stateURL.path))
    }

    private struct UnwritableSink: TelemetrySink {
        struct Unwritable: Error {}
        func export(metrics: OTLP.MetricsRequest, at date: Date) throws { throw Unwritable() }
        func export(logs: OTLP.LogsRequest, at date: Date) throws { throw Unwritable() }
        func prune(retentionDays: Int, now: Date) throws {}
    }

    @Test func eventsSurviveAFailedWrite() async throws {
        let base = try temporaryDirectory()
        let output = base.appending(path: "out", directoryHint: .isDirectory)
        let recorder = TelemetryRecorder(
            stateURL: base.appending(path: "state/telemetry-state.json"),
            scanner: TranscriptTokenScanner(root: base.appending(path: "projects", directoryHint: .isDirectory)),
            resource: .init(attributes: []),
            scope: .init(name: "t", version: "1")
        )
        let start = Date()
        _ = await recorder.stamp(
            usage: UsageResponse(limits: [limit("session", group: "session", percent: 70)]),
            offers: AccountOffers(), sinks: [FileTelemetrySink(directory: output)], retentionDays: 90, now: start
        )

        let reset = UsageResponse(limits: [limit("session", group: "session", percent: 0)])
        let failed = await recorder.stamp(
            usage: reset, offers: AccountOffers(), sinks: [UnwritableSink()], retentionDays: 90,
            now: start.addingTimeInterval(300)
        )
        #expect(!failed.problems.isEmpty)
        #expect(failed.eventNames.isEmpty)

        let retried = await recorder.stamp(
            usage: reset, offers: AccountOffers(), sinks: [FileTelemetrySink(directory: output)], retentionDays: 90,
            now: start.addingTimeInterval(600)
        )
        #expect(retried.problems.isEmpty)
        #expect(retried.eventNames == ["limit.reset"])
    }

    @Test func tokensWrittenBeforeTheFirstStampStillCount() async throws {
        let base = try temporaryDirectory()
        let transcripts = base.appending(path: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
        let transcript = transcripts.appending(path: "s.jsonl")
        try append(usageLine(id: "before", request: "r0") + "\n", to: transcript)
        let recorder = TelemetryRecorder(
            stateURL: base.appending(path: "state/telemetry-state.json"),
            scanner: TranscriptTokenScanner(root: transcripts),
            resource: .init(attributes: []),
            scope: .init(name: "t", version: "1")
        )
        let start = Date()
        #expect(await recorder.startCounting(now: start).isEmpty)

        // Written while the first stamp waits for usage: after opting in, so it counts.
        try append(usageLine(id: "waiting", request: "r1") + "\n", to: transcript)
        let output = base.appending(path: "out", directoryHint: .isDirectory)
        _ = await recorder.stamp(
            usage: nil, offers: AccountOffers(), sinks: [FileTelemetrySink(directory: output)], retentionDays: 90,
            now: start.addingTimeInterval(30)
        )
        let metricsFile = output.appending(path: FileTelemetrySink.fileName(prefix: "metrics", on: start))
        let line = try String(contentsOf: metricsFile, encoding: .utf8)
        #expect(line.contains("\"claude.code.messages\""))
        #expect(line.contains("\"asInt\":\"1\""))
    }

    @Test func keepForeverNeverPrunes() async throws {
        let base = try temporaryDirectory()
        let output = base.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let now = Date()
        let ancient = Calendar.current.date(byAdding: .day, value: -4000, to: now) ?? now
        let oldFile = output.appending(path: FileTelemetrySink.fileName(prefix: "metrics", on: ancient))
        FileManager.default.createFile(atPath: oldFile.path, contents: Data())

        let recorder = TelemetryRecorder(
            stateURL: base.appending(path: "state/telemetry-state.json"),
            scanner: TranscriptTokenScanner(root: base.appending(path: "projects", directoryHint: .isDirectory)),
            resource: .init(attributes: []),
            scope: .init(name: "t", version: "1")
        )
        let report = await recorder.stamp(
            usage: UsageResponse(limits: [limit("session", group: "session", percent: 10)]),
            offers: AccountOffers(),
            sinks: [FileTelemetrySink(directory: output)], retentionDays: nil, now: now
        )
        #expect(report.problems.isEmpty)
        #expect(FileManager.default.fileExists(atPath: oldFile.path))
    }
}

// MARK: - Wire decoding

struct TelemetryDecodingTests {
    @Test func extraUsageDecodesAndBadShapeKeepsLimits() throws {
        let good = #"{"limits":[],"extra_usage":{"is_enabled":true,"monthly_limit":50000,"used_credits":27140,"utilization":54,"currency":"USD","decimal_places":2,"disabled_reason":null}}"#
        let response = try JSONDecoder().decode(UsageResponse.self, from: Data(good.utf8))
        #expect(response.extraUsage?.isEnabled == true)
        #expect(response.extraUsage?.usedCredits == 27140)
        #expect(response.extraUsage?.decimalPlaces == 2)

        let bad = #"{"limits":[{"kind":"session","percent":5}],"extra_usage":"surprise"}"#
        let degraded = try JSONDecoder().decode(UsageResponse.self, from: Data(bad.utf8))
        #expect(degraded.limits.count == 1)
        #expect(degraded.extraUsage == nil)
    }

    @Test func eligibilityShapeDecodesWithoutReadingTheCode() throws {
        // Shape as Claude Code caches it; the code and links are present but never decoded.
        let json = #"{"eligible":true,"referral_code_details":{"code":"SECRET","campaign":"claude_code_guest_pass_x","referral_link":"https://example.invalid/r/SECRET"},"referrer_reward":{"amount_minor_units":1500,"currency":"AUD"},"remaining_passes":2,"limit":3,"share_link":"https://example.invalid/r/SECRET"}"#
        let eligibility = try JSONDecoder().decode(AccountClient.Eligibility.self, from: Data(json.utf8))
        #expect(eligibility.eligible == true)
        #expect(eligibility.remainingPasses == 2)
        #expect(eligibility.limit == 3)
        #expect(eligibility.referralCodeDetails?.campaign == "claude_code_guest_pass_x")
        #expect(eligibility.referrerReward?.amountMinorUnits == 1500)
    }

    @Test func creditGrantShapeDecodes() throws {
        let json = #"{"available":false,"eligible":false,"granted":false,"amount_minor_units":null,"currency":null}"#
        let grant = try JSONDecoder().decode(AccountClient.Grant.self, from: Data(json.utf8))
        #expect(grant.available == false)
        #expect(grant.amountMinorUnits == nil)
    }

    @Test func organizationFallbackReadsClaudeConfig() throws {
        let file = try temporaryDirectory().appending(path: ".claude.json")
        try Data(#"{"oauthAccount":{"organizationUuid":"org-123"}}"#.utf8).write(to: file)
        #expect(AccountClient.organizationUUIDFromClaudeConfig(url: file) == "org-123")
        #expect(AccountClient.organizationUUIDFromClaudeConfig(url: file.appending(path: "missing")) == nil)
    }
}
