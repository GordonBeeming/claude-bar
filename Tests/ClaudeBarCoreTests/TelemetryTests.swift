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

    @Test func logRecordCarriesEventNameAtTopLevelOnly() throws {
        let request = OTLP.LogsRequest(resource: resource, scope: scope, logRecords: [
            .init(time: Date(timeIntervalSince1970: 1), eventName: "limit.reset", body: "Session reset", attributes: [.init("percent", .double(0))]),
        ])
        let root = try jsonObject(OTLP.encodeLine(request))
        let resourceLogs = try #require(root["resourceLogs"] as? [[String: Any]])
        let scopeLogs = try #require(resourceLogs.first?["scopeLogs"] as? [[String: Any]])
        let record = try #require((scopeLogs.first?["logRecords"] as? [[String: Any]])?.first)
        #expect(record["severityNumber"] as? Int == 9)
        #expect((record["body"] as? [String: Any])?["stringValue"] as? String == "Session reset")
        #expect(record["eventName"] as? String == "limit.reset")
        #expect(record["timeUnixNano"] as? String == record["observedTimeUnixNano"] as? String)
        let attributes = try #require(record["attributes"] as? [[String: Any]])
        #expect(attributes.map { $0["key"] as? String } == ["percent"])
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

    @Test func usageWithoutAModelCountsAsUnknown() throws {
        let line = #"{"requestId":"r","message":{"id":"m","usage":{"input_tokens":7,"output_tokens":3}}}"#
        let usage = try #require(TranscriptTokenScanner.parse(line: Data(line.utf8)))
        #expect(usage.model == "unknown")
        #expect(usage.input == 7)
        #expect(usage.output == 3)
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
        let utilization = try #require(metrics.first { $0.name == "bar.limit.utilization" })
        #expect(utilization.dataPoints.count == 2)
        let scoped = try #require(utilization.dataPoints.first { point in point.attributes.contains(.init("model.name", .string("Fable"))) })
        #expect(scoped.value == .double(27))
        #expect(scoped.attributes.contains(.init("limit.kind", .string("weekly_scoped"))))
        // No model ID from the API, so the display name keeps it apart from other scoped limits.
        #expect(scoped.attributes.contains(.init("limit.id", .string("weekly_scoped:Fable"))))
        #expect(scoped.attributes.contains(.init("limit.window.duration_minutes", .int(10080))))
        #expect(!scoped.attributes.contains { $0.key == "model.id" })

        let session = try #require(utilization.dataPoints.first { $0.attributes.contains(.init("limit.id", .string("session"))) })
        #expect(session.attributes.contains(.init("limit.name", .string("Session (5h)"))))
        #expect(session.attributes.contains(.init("limit.window.duration_minutes", .int(300))))

        // Only the session limit has a reset time; the scoped one contributes no point.
        let resets = try #require(metrics.first { $0.name == "bar.limit.resets_at" })
        #expect(resets.dataPoints.count == 1)
        #expect(resets.dataPoints.first?.value == .int(Int64(now.timeIntervalSince1970) + 3600))
    }

    @Test func scopedLimitIDUsesModelID() throws {
        let usage = UsageResponse(limits: [
            UsageLimit(kind: "weekly_scoped", group: "weekly", percent: 4, severity: .normal,
                       scope: LimitScope(model: .init(id: "claude-opus-4-1", displayName: "Opus"))),
            // A group with no known cadence still gets written, just without a window length.
            UsageLimit(kind: "monthly_all", group: "monthly", percent: 9, severity: .normal),
        ])
        let utilization = try #require(
            TelemetryStamp.metrics(usage: usage, offers: AccountOffers(), tokens: nil, now: now).first { $0.name == "bar.limit.utilization" }
        )
        let scoped = try #require(utilization.dataPoints.first { $0.attributes.contains(.init("model.id", .string("claude-opus-4-1"))) })
        #expect(scoped.attributes.contains(.init("limit.id", .string("weekly_scoped:claude-opus-4-1"))))
        let monthly = try #require(utilization.dataPoints.first { $0.attributes.contains(.init("limit.id", .string("monthly_all"))) })
        #expect(!monthly.attributes.contains { $0.key == "limit.window.duration_minutes" })
    }

    @Test func limitsSharingAnIDWriteNoBarPoints() throws {
        let usage = UsageResponse(limits: [
            limit("session", group: "session", percent: 3),
            limit("weekly_scoped", group: "weekly", percent: 90),
            limit("weekly_scoped", group: "weekly", percent: 5),
        ])
        let utilization = try #require(
            TelemetryStamp.metrics(usage: usage, offers: AccountOffers(), tokens: nil, now: now).first { $0.name == "bar.limit.utilization" }
        )
        #expect(utilization.dataPoints.count == 1)
    }

    @Test func perksBecomeOneGaugeInMajorUnits() throws {
        let offers = AccountOffers(
            guestPasses: GuestPassStatus(campaign: "c", eligible: true, remaining: 2, limit: 3),
            creditGrant: CreditGrantStatus(campaign: "g", available: true, eligible: true, granted: false, amountMinorUnits: 2050, currency: "usd")
        )
        let perks = try #require(
            TelemetryStamp.metrics(usage: nil, offers: offers, tokens: nil, now: now).first { $0.name == "bar.perk.available" }
        )
        let pass = try #require(perks.dataPoints.first { $0.attributes.contains(.init("perk.kind", .string("guest_pass"))) })
        #expect(pass.value == .int(2))
        let grant = try #require(perks.dataPoints.first { $0.attributes.contains(.init("perk.kind", .string("credit_grant"))) })
        #expect(grant.value == .double(20.5))
        #expect(grant.attributes.contains(.init("perk.currency", .string("USD"))))
    }

    @Test func creditGrantWithoutCurrencyIsLeftOut() {
        let offers = AccountOffers(creditGrant: CreditGrantStatus(campaign: "g", available: true, eligible: true, granted: false, amountMinorUnits: 2000))
        let names = TelemetryStamp.metrics(usage: nil, offers: offers, tokens: nil, now: now).map(\.name)
        #expect(!names.contains("bar.perk.available"))
    }

    @Test func currencyExponentFollowsISO4217() {
        #expect(TelemetryStamp.currencyExponent("USD") == 2)
        #expect(TelemetryStamp.currencyExponent("JPY") == 0)
        #expect(TelemetryStamp.majorUnits(500, currency: "JPY") == 500)
        #expect(TelemetryStamp.majorUnits(1234, currency: "AUD") == 12.34)
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
        let events = TelemetryStamp.events(previous: before, current: after, now: now)
        let names = events.map(\.eventName)
        // No reset times here, so the usage drop is what reads as a reset.
        #expect(names.filter { $0 == "bar.limit.reset" }.count == 1)
        #expect(names.filter { $0 == "claude.limit.severity_changed" }.count == 2)
        let reset = events.first { $0.eventName == "bar.limit.reset" }
        #expect(reset?.attributes.contains(.init("limit.utilization.last", .double(80))) == true)
        #expect(reset?.attributes.contains(.init("limit.id", .string("session"))) == true)
    }

    @Test func resetIsTheWindowRollingOver() throws {
        let oldEnd = now.addingTimeInterval(-30)
        let newEnd = now.addingTimeInterval(5 * 3600)
        let before = TelemetryStamp.observe(
            usage: UsageResponse(limits: [limit("session", group: "session", percent: 40, resetsAt: oldEnd)]),
            offers: AccountOffers(), previous: nil
        )
        // Usage after the rollover is already above zero, which the usage-drop rule would miss.
        let after = TelemetryStamp.observe(
            usage: UsageResponse(limits: [limit("session", group: "session", percent: 12, resetsAt: newEnd)]),
            offers: AccountOffers(), previous: before
        )
        let reset = try #require(TelemetryStamp.events(previous: before, current: after, now: now).first)
        #expect(reset.eventName == "bar.limit.reset")
        #expect(reset.attributes.contains(.init("limit.utilization.last", .double(40))))
        #expect(reset.attributes.contains(.init("limit.resets_at.next", .int(Int64(newEnd.timeIntervalSince1970)))))
        #expect(reset.attributes.contains(.init("limit.window.duration_minutes", .int(300))))

        // The reset time moving while the old window is still running isn't a rollover.
        let early = TelemetryStamp.observe(
            usage: UsageResponse(limits: [limit("session", group: "session", percent: 40, resetsAt: now.addingTimeInterval(3600))]),
            offers: AccountOffers(), previous: nil
        )
        let nudged = TelemetryStamp.observe(
            usage: UsageResponse(limits: [limit("session", group: "session", percent: 41, resetsAt: now.addingTimeInterval(7200))]),
            offers: AccountOffers(), previous: early
        )
        #expect(TelemetryStamp.events(previous: early, current: nudged, now: now).isEmpty)
    }

    @Test func resetIsStillCaughtWhenTheEndMovedEarly() throws {
        // The API moves the end forward while the old window is still running, then usage
        // falls at the real rollover with the end unchanged.
        let end = now.addingTimeInterval(7200)
        let early = TelemetryStamp.observe(
            usage: UsageResponse(limits: [limit("session", group: "session", percent: 70, resetsAt: now.addingTimeInterval(3600))]),
            offers: AccountOffers(), previous: nil
        )
        let moved = TelemetryStamp.observe(
            usage: UsageResponse(limits: [limit("session", group: "session", percent: 72, resetsAt: end)]),
            offers: AccountOffers(), previous: early
        )
        #expect(TelemetryStamp.events(previous: early, current: moved, now: now).isEmpty)
        let rolled = TelemetryStamp.observe(
            usage: UsageResponse(limits: [limit("session", group: "session", percent: 0, resetsAt: end)]),
            offers: AccountOffers(), previous: moved
        )
        let reset = try #require(TelemetryStamp.events(previous: moved, current: rolled, now: now.addingTimeInterval(3700)).first)
        #expect(reset.eventName == "bar.limit.reset")
        #expect(reset.attributes.contains(.init("limit.utilization.last", .double(72))))
    }

    @Test func limitsSharingAnIDFireNoEvents() {
        // Same model ID, different display names: distinct keys, one `limit.id` on the wire.
        func scoped(_ name: String, _ percent: Double, severity: Severity = .normal) -> UsageLimit {
            UsageLimit(kind: "weekly_scoped", group: "weekly", percent: percent, severity: severity,
                       scope: LimitScope(model: .init(id: "claude-opus-4-1", displayName: name)))
        }
        let before = TelemetryStamp.observe(
            usage: UsageResponse(limits: [scoped("Opus", 90, severity: .critical), scoped("Opus 4.1", 5)]),
            offers: AccountOffers(), previous: nil
        )
        let after = TelemetryStamp.observe(
            usage: UsageResponse(limits: [scoped("Opus", 0), scoped("Opus 4.1", 5)]),
            offers: AccountOffers(), previous: before
        )
        #expect(TelemetryStamp.events(previous: before, current: after, now: now).isEmpty)
    }

    @Test func limitEventsFromOldStateStillCarryALimitID() throws {
        // State saved by the previous version has no `limit.id` attribute.
        let key = ["weekly_scoped", "claude-opus-4-1", "Opus"].joined(separator: "\u{1}")
        let previous = ObservedState(limits: [
            key: .init(percent: 5, severity: "normal", resetsAt: nil, attributes: ["limit.kind": "weekly_scoped", "limit.name": "Weekly — Opus", "limit.group": "weekly"]),
        ])
        let current = TelemetryStamp.observe(usage: UsageResponse(limits: []), offers: AccountOffers(), previous: previous)
        let gone = try #require(TelemetryStamp.events(previous: previous, current: current, now: now).first)
        #expect(gone.eventName == "bar.limit.disappeared")
        #expect(gone.attributes.contains(.init("limit.id", .string("weekly_scoped:claude-opus-4-1"))))
        #expect(gone.attributes.contains(.init("model.id", .string("claude-opus-4-1"))))
        #expect(gone.attributes.contains(.init("limit.window.duration_minutes", .int(10080))))
    }

    @Test func newScopedLimitAppears() {
        let before = TelemetryStamp.observe(usage: UsageResponse(limits: [limit("session", group: "session", percent: 1)]), offers: AccountOffers(), previous: nil)
        let after = TelemetryStamp.observe(
            usage: UsageResponse(limits: [limit("session", group: "session", percent: 1), limit("weekly_scoped", group: "weekly", percent: 0, model: "Fable")]),
            offers: AccountOffers(),
            previous: before
        )
        #expect(TelemetryStamp.events(previous: before, current: after, now: now).map(\.eventName) == ["bar.limit.appeared"])
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
        event.attributes.first { $0.key == "perk.gone.reason" }.flatMap {
            if case .string(let value) = $0.value { value } else { nil }
        }
    }

    private func quantity(_ event: OTLP.LogRecord) -> OTLP.AnyValue? {
        event.attributes.first { $0.key == "perk.quantity" }?.value
    }

    @Test func guestPassRedeemedIsUsed() throws {
        let before = TelemetryStamp.observe(usage: nil, offers: passes(3), previous: ObservedState())
        let after = TelemetryStamp.observe(usage: nil, offers: passes(2), previous: before)
        let event = try #require(TelemetryStamp.events(previous: before, current: after, now: now).first)
        #expect(event.eventName == "bar.perk.gone")
        #expect(reason(event) == "used")
        #expect(quantity(event) == .int(1))
    }

    @Test func guestPassesWithdrawnHaveNoReason() throws {
        let before = TelemetryStamp.observe(usage: nil, offers: passes(2), previous: ObservedState())
        let after = TelemetryStamp.observe(usage: nil, offers: passes(nil, eligible: false), previous: before)
        let event = try #require(TelemetryStamp.events(previous: before, current: after, now: now).first)
        #expect(event.eventName == "bar.perk.gone")
        #expect(event.attributes.contains(.init("perk.kind", .string("guest_pass"))))
        #expect(reason(event) == nil)
        #expect(quantity(event) == .int(2))
    }

    @Test func guestPassesAppear() throws {
        let before = TelemetryStamp.observe(usage: nil, offers: passes(nil, eligible: false), previous: ObservedState())
        let after = TelemetryStamp.observe(usage: nil, offers: passes(3), previous: before)
        let events = TelemetryStamp.events(previous: before, current: after, now: now)
        #expect(events.map(\.eventName) == ["bar.perk.available"])
        #expect(quantity(try #require(events.first)) == .int(3))
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
        let appeared = TelemetryStamp.events(previous: unclaimable, current: before, now: now)
        #expect(appeared.map(\.eventName) == ["bar.perk.available"])
        let available = try #require(appeared.first)
        #expect(quantity(available) == .double(20))
        #expect(available.attributes.contains(.init("perk.currency", .string("USD"))))

        let after = TelemetryStamp.observe(usage: nil, offers: grant(available: false, granted: true), previous: before)
        let event = try #require(TelemetryStamp.events(previous: before, current: after, now: now).first)
        #expect(event.eventName == "bar.perk.gone")
        #expect(reason(event) == "used")
        #expect(quantity(event) == .double(20))
    }

    @Test func creditGrantWithEmptyCurrencyHasNoQuantity() throws {
        let offers = { (available: Bool) in
            AccountOffers(creditGrant: CreditGrantStatus(campaign: "g", available: available, eligible: true, granted: false, amountMinorUnits: 2000, currency: ""))
        }
        let before = TelemetryStamp.observe(usage: nil, offers: offers(false), previous: ObservedState())
        let after = TelemetryStamp.observe(usage: nil, offers: offers(true), previous: before)
        let event = try #require(TelemetryStamp.events(previous: before, current: after, now: now).first)
        #expect(event.eventName == "bar.perk.available")
        #expect(quantity(event) == nil)
        #expect(!event.attributes.contains { $0.key == "perk.currency" })
    }

    @Test func creditGrantGoneWithoutBeingGrantedHasNoReason() throws {
        // A usage drop alongside it is only a guess at redemption, so Bar UI decides instead.
        let resets = now.addingTimeInterval(86_400)
        let before = TelemetryStamp.observe(usage: UsageResponse(limits: [limit("weekly_all", group: "weekly", percent: 90, resetsAt: resets)]), offers: grant(available: true), previous: ObservedState())
        let after = TelemetryStamp.observe(usage: UsageResponse(limits: [limit("weekly_all", group: "weekly", percent: 60, resetsAt: resets)]), offers: grant(available: false), previous: before)
        let event = try #require(TelemetryStamp.events(previous: before, current: after, now: now).first { $0.eventName == "bar.perk.gone" })
        #expect(reason(event) == nil)
        #expect(event.attributes.contains(.init("perk.kind", .string("credit_grant"))))
        #expect(event.attributes.contains(.init("perk.currency", .string("USD"))))
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

        let todayFile = directory.appending(path: sink.fileName(kind: "metrics", on: now))
        #expect(todayFile.lastPathComponent.hasPrefix("claudebar-metrics-"))
        let lines = try String(contentsOf: todayFile, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)

        let old = Calendar.current.date(byAdding: .day, value: -100, to: now) ?? now
        let oldFile = directory.appending(path: sink.fileName(kind: "logs", on: old))
        let foreign = directory.appending(path: "notes.txt")
        // Files an older version named without the service prefix are the person's to clear.
        let legacy = directory.appending(path: "metrics-2020-01-01.jsonl")
        for file in [oldFile, foreign, legacy] {
            FileManager.default.createFile(atPath: file.path, contents: Data())
        }

        try sink.prune(retentionDays: 90, now: now)
        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
        #expect(FileManager.default.fileExists(atPath: todayFile.path))
        #expect(FileManager.default.fileExists(atPath: foreign.path))
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test func fileDateIsUTCNotLocal() throws {
        // Pin a non-UTC local zone so a regression to local dates fails even on a UTC CI host.
        // `TimeZone.current` ignores `NSTimeZone.default`; it follows `TZ` once the system zone
        // is reset. No other test reads the process zone, so this can't disturb them.
        let originalTZ = ProcessInfo.processInfo.environment["TZ"]
        setenv("TZ", "Australia/Brisbane", 1)
        NSTimeZone.resetSystemTimeZone()
        defer {
            if let originalTZ { setenv("TZ", originalTZ, 1) } else { unsetenv("TZ") }
            NSTimeZone.resetSystemTimeZone()
        }
        try #require(TimeZone.current.identifier == "Australia/Brisbane")

        let sink = FileTelemetrySink(directory: URL(filePath: "/tmp"))
        // 23:30 UTC on 1 Jan is already 2 Jan in Brisbane; the file still says 1 Jan.
        let lateUTC = Date(timeIntervalSince1970: 1_767_310_200) // 2026-01-01T23:30:00Z
        #expect(sink.fileName(kind: "logs", on: lateUTC) == "claudebar-logs-2026-01-01.jsonl")
        #expect(sink.date(fromFileName: "claudebar-logs-2026-01-01.jsonl") == Date(timeIntervalSince1970: 1_767_225_600))
        #expect(sink.date(fromFileName: "logs-2026-01-01.jsonl") == nil)
        #expect(sink.date(fromFileName: "claudebar-logs-2026-01-01.jsonl.bak") == nil)
    }

    @Test func createsPrivateFolderAndFiles() throws {
        let directory = try temporaryDirectory().appending(path: "new", directoryHint: .isDirectory)
        let sink = FileTelemetrySink(directory: directory)
        let now = Date()
        try sink.export(logs: .init(resource: .init(attributes: []), scope: .init(name: "t", version: "1"), logRecords: [
            .init(time: now, eventName: "e", body: "", attributes: []),
        ]), at: now)
        let folderMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        let fileMode = try FileManager.default.attributesOfItem(
            atPath: directory.appending(path: sink.fileName(kind: "logs", on: now)).path
        )[.posixPermissions] as? Int
        #expect(folderMode == 0o700)
        #expect(fileMode == 0o600)
    }

    @Test func folderHelperOnlySetsPermissionsOnFoldersItCreates() throws {
        let base = try temporaryDirectory()
        let created = base.appending(path: "new", directoryHint: .isDirectory)
        try FileTelemetrySink.createFolderIfNeeded(created)
        #expect(try FileManager.default.attributesOfItem(atPath: created.path)[.posixPermissions] as? Int == 0o700)

        let existing = base.appending(path: "picked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try FileTelemetrySink.createFolderIfNeeded(existing)
        #expect(try FileManager.default.attributesOfItem(atPath: existing.path)[.posixPermissions] as? Int == 0o755)
    }

    @Test func partialLastLineIsCutBeforeAppending() throws {
        let directory = try temporaryDirectory()
        let sink = FileTelemetrySink(directory: directory)
        let now = Date()
        let file = directory.appending(path: sink.fileName(kind: "logs", on: now))
        try Data("{\"whole\":1}\n{\"torn\":".utf8).write(to: file)

        try sink.export(logs: .init(resource: .init(attributes: []), scope: .init(name: "t", version: "1"), logRecords: [
            .init(time: now, eventName: "e", body: "", attributes: []),
        ]), at: now)
        let text = try String(contentsOf: file, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(text.hasSuffix("\n"))
        #expect(lines.count == 2)
        #expect(lines[0] == "{\"whole\":1}")
        #expect(lines[1].hasPrefix("{\"resourceLogs\""))
    }

    @Test func fileWithOnlyAFragmentStartsEmpty() throws {
        let directory = try temporaryDirectory()
        let file = directory.appending(path: "f.jsonl")
        try Data("{\"torn\":".utf8).write(to: file)
        let handle = try FileHandle(forUpdating: file)
        try FileTelemetrySink.dropPartialLastLine(handle)
        try handle.close()
        #expect(try Data(contentsOf: file).isEmpty)
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
            sinks: sinks, retentionDays: 90, intervalMinutes: 5, now: start
        )
        #expect(first.problems.isEmpty)
        #expect(first.eventNames == ["bar.tracking.started"])
        #expect(FileManager.default.fileExists(atPath: stateURL.path))
        let logsFile = output.appending(path: FileTelemetrySink(directory: output).fileName(kind: "logs", on: start))
        let startedLine = try String(contentsOf: logsFile, encoding: .utf8)
        #expect(startedLine.contains("\"eventName\":\"bar.tracking.started\""))
        #expect(startedLine.contains("\"tracking.interval_minutes\""))

        try append(usageLine(id: "after", request: "r1") + "\n", to: transcript)
        let second = await recorder.stamp(
            usage: UsageResponse(limits: [limit("session", group: "session", percent: 0)]),
            offers: AccountOffers(),
            sinks: sinks, retentionDays: 90, intervalMinutes: 5, now: start.addingTimeInterval(300)
        )
        #expect(second.problems.isEmpty)
        #expect(second.eventNames == ["bar.limit.reset"])

        let metricsFile = output.appending(path: FileTelemetrySink(directory: output).fileName(kind: "metrics", on: start))
        let lines = try String(contentsOf: metricsFile, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        // Only the message written after opting in is counted.
        let last = String(lines[1])
        #expect(last.contains("\"bar.tokens\""))
        #expect(last.contains("\"asInt\":\"20\""))
        #expect(!last.contains("claude.code.tokens"))
        #expect(!String(lines[0]).contains("bar.tokens"))

        try await recorder.reset()
        #expect(!FileManager.default.fileExists(atPath: stateURL.path))

        // Counting restarts after a reset, and says so again.
        let restarted = await recorder.stamp(
            usage: nil, offers: AccountOffers(),
            sinks: sinks, retentionDays: 90, intervalMinutes: 15, now: start.addingTimeInterval(900)
        )
        #expect(restarted.eventNames == ["bar.tracking.started"])
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
            offers: AccountOffers(), sinks: [FileTelemetrySink(directory: output)], retentionDays: 90, intervalMinutes: 5, now: start
        )

        let reset = UsageResponse(limits: [limit("session", group: "session", percent: 0)])
        let failed = await recorder.stamp(
            usage: reset, offers: AccountOffers(), sinks: [UnwritableSink()], retentionDays: 90, intervalMinutes: 5,
            now: start.addingTimeInterval(300)
        )
        #expect(!failed.problems.isEmpty)
        #expect(failed.eventNames.isEmpty)

        let retried = await recorder.stamp(
            usage: reset, offers: AccountOffers(), sinks: [FileTelemetrySink(directory: output)], retentionDays: 90, intervalMinutes: 5,
            now: start.addingTimeInterval(600)
        )
        #expect(retried.problems.isEmpty)
        #expect(retried.eventNames == ["bar.limit.reset"])
    }

    @Test func upgradedStateWritesOneStartEventAtItsOriginalStart() async throws {
        let base = try temporaryDirectory()
        let output = base.appending(path: "out", directoryHint: .isDirectory)
        let stateURL = base.appending(path: "state/telemetry-state.json")
        let scanner = TranscriptTokenScanner(root: base.appending(path: "projects", directoryHint: .isDirectory))
        func makeRecorder() -> TelemetryRecorder {
            TelemetryRecorder(stateURL: stateURL, scanner: scanner, resource: .init(attributes: []), scope: .init(name: "t", version: "1"))
        }
        let countingSince = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(await makeRecorder().startCounting(now: countingSince).isEmpty)

        // Strip what this version adds, leaving the state an install from before the spec saved.
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        json.removeValue(forKey: "specVersion")
        json.removeValue(forKey: "trackingStartPending")
        try JSONSerialization.data(withJSONObject: json).write(to: stateURL)

        let recorder = makeRecorder()
        let now = countingSince.addingTimeInterval(86_400)
        let first = await recorder.stamp(
            usage: nil, offers: AccountOffers(), sinks: [FileTelemetrySink(directory: output)],
            retentionDays: 90, intervalMinutes: 5, now: now
        )
        #expect(first.eventNames == ["bar.tracking.started"])
        let logs = try String(contentsOf: output.appending(path: FileTelemetrySink(directory: output).fileName(kind: "logs", on: now)), encoding: .utf8)
        #expect(logs.contains("\"timeUnixNano\":\"1790000000000000000\""))

        let second = await recorder.stamp(
            usage: nil, offers: AccountOffers(), sinks: [FileTelemetrySink(directory: output)],
            retentionDays: 90, intervalMinutes: 5, now: now.addingTimeInterval(300)
        )
        #expect(second.eventNames.isEmpty)
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
            usage: nil, offers: AccountOffers(), sinks: [FileTelemetrySink(directory: output)], retentionDays: 90, intervalMinutes: 5,
            now: start.addingTimeInterval(30)
        )
        let metricsFile = output.appending(path: FileTelemetrySink(directory: output).fileName(kind: "metrics", on: start))
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
        let oldFile = output.appending(path: FileTelemetrySink(directory: output).fileName(kind: "metrics", on: ancient))
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
            sinks: [FileTelemetrySink(directory: output)], retentionDays: nil, intervalMinutes: 5, now: now
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
