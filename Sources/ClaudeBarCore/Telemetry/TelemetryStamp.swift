import Foundation

/// What the previous stamp saw, kept so the next one can tell what changed. Persisted so an
/// offer that appears or goes while the app is closed still gets an event on the next stamp.
public struct ObservedState: Codable, Sendable, Equatable {
    public struct Limit: Codable, Sendable, Equatable {
        public let percent: Double
        public let severity: String
        public let resetsAt: Date?
        public let attributes: [String: String]
    }

    public struct Extra: Codable, Sendable, Equatable {
        public let isEnabled: Bool?
        public let monthlyLimit: Double?
        public let usedCredits: Double?
    }

    public var limits: [String: Limit]?
    /// Keys shared by more than one limit in the same response (scoped limits with no model
    /// identity). Which one is which can't be told apart between stamps, so they're kept out
    /// of `limits` and never compared, the same rule celebrations follow.
    public var ambiguousLimitKeys: Set<String>?
    public var extraUsage: Extra?
    public var offers: AccountOffers

    public init(
        limits: [String: Limit]? = nil,
        ambiguousLimitKeys: Set<String>? = nil,
        extraUsage: Extra? = nil,
        offers: AccountOffers = AccountOffers()
    ) {
        self.limits = limits
        self.ambiguousLimitKeys = ambiguousLimitKeys
        self.extraUsage = extraUsage
        self.offers = offers
    }
}

/// Builds one stamp's metrics and events from what the app currently knows, in the shape the
/// Bar Telemetry Spec (v1) defines for `bar.*` names. Pure, so the whole mapping is
/// unit-tested without a clock, network, or disk.
public enum TelemetryStamp {
    public static let specVersion = "1"

    /// How far a limit's reset time has to move later before it counts as a new window
    /// rather than the API nudging the same one.
    static let windowRolloverTolerance: TimeInterval = 60

    // MARK: Metrics

    public static func metrics(
        usage: UsageResponse?,
        offers: AccountOffers,
        tokens: TranscriptScanState?,
        now: Date
    ) -> [OTLP.Metric] {
        var metrics: [OTLP.Metric] = []

        if let usage, !usage.limits.isEmpty {
            // Two limits with one `limit.id` would write two points for the same series in one
            // metric, and no reader can tell which is which, so neither is written.
            let duplicateIDs = Set(Dictionary(grouping: usage.limits, by: limitID).filter { $0.value.count > 1 }.keys)
            let limits = usage.limits
                .filter { !duplicateIDs.contains(limitID($0)) }
                .map { (limit: $0, attributes: limitAttributes($0)) }
            metrics.append(gauge(
                "bar.limit.utilization", unit: "%",
                "Share of the limit's allowance used in its current window.",
                limits.map { point($0.attributes, now, .double($0.limit.percent)) }
            ))
            metrics.append(gauge(
                "bar.limit.resets_at", unit: "s",
                "When the limit's current window ends, as Unix seconds.",
                limits.compactMap { entry in
                    entry.limit.resetsAt.map { point(entry.attributes, now, .int(unixSeconds($0))) }
                }
            ))
            metrics.append(gauge(
                "claude.usage.limit.window_elapsed", unit: "%",
                "How far through its window the limit is; utilization above this is burning over pace.",
                limits.compactMap { entry in
                    UsageWindow.paceFraction(for: entry.limit, now: now).map {
                        point(entry.attributes, now, .double(($0 * 100 * 100).rounded() / 100))
                    }
                }
            ))
        }

        if let extra = usage?.extraUsage {
            var attributes: [OTLP.KeyValue] = []
            if let currency = extra.currency { attributes.append(.init("currency", .string(currency))) }
            if let places = extra.decimalPlaces { attributes.append(.init("decimal_places", .int(Int64(places)))) }
            if let enabled = extra.isEnabled {
                metrics.append(gauge(
                    "claude.extra_usage.enabled", unit: "1",
                    "1 when pay-as-you-go extra usage is switched on, 0 when it's off.",
                    [point(attributes, now, .int(enabled ? 1 : 0))]
                ))
            }
            if let used = extra.usedCredits {
                metrics.append(gauge(
                    "claude.extra_usage.used_credits", unit: "{credit}",
                    "Extra-usage credits spent this month, as the API reports them.",
                    [point(attributes, now, .double(used))]
                ))
            }
            if let limit = extra.monthlyLimit {
                metrics.append(gauge(
                    "claude.extra_usage.monthly_limit", unit: "{credit}",
                    "The monthly extra-usage spend cap, as the API reports it.",
                    [point(attributes, now, .double(limit))]
                ))
            }
            if let utilization = extra.utilization {
                metrics.append(gauge(
                    "claude.extra_usage.utilization", unit: "%",
                    "Share of the monthly extra-usage cap spent.",
                    [point(attributes, now, .double(utilization))]
                ))
            }
        }

        var perkPoints: [OTLP.NumberDataPoint] = []
        if let passes = offers.guestPasses {
            perkPoints.append(point(guestPassAttributes(passes), now, .int(Int64(availablePasses(passes)))))
            if let limit = passes.limit {
                metrics.append(gauge(
                    "claude.guest_passes.limit", unit: "{pass}",
                    "Guest passes the account gets in total.",
                    [point([.init("claude.campaign", .string(passes.campaign))], now, .int(Int64(limit)))]
                ))
            }
        }
        // `perk.currency` is required for a credit grant, so a grant whose currency or amount
        // the API left out can't be written as one.
        if let grant = offers.creditGrant, let amount = availableGrantAmount(grant), let attributes = creditGrantAttributes(grant) {
            perkPoints.append(point(attributes, now, .double(amount)))
        }
        metrics.append(gauge(
            "bar.perk.available", unit: "1",
            "Perks on the account: guest passes as a count, credit grants as an amount in perk.currency.",
            perkPoints
        ))

        if let tokens, !tokens.totals.isEmpty {
            metrics.append(contentsOf: tokenMetrics(tokens, now: now))
        }

        // A metric with no points (no limit had a reset time, say) is noise to every consumer.
        return metrics.filter { !$0.dataPoints.isEmpty }
    }

    private static func tokenMetrics(_ tokens: TranscriptScanState, now: Date) -> [OTLP.Metric] {
        let start = tokens.countingSince
        let models = tokens.totals.keys.sorted()
        var tokenPoints: [OTLP.NumberDataPoint] = []
        var messagePoints: [OTLP.NumberDataPoint] = []
        var toolPoints: [OTLP.NumberDataPoint] = []
        for model in models {
            guard let totals = tokens.totals[model] else { continue }
            let modelAttribute = OTLP.KeyValue("model", .string(model))
            let byType: [(String, Int64)] = [
                ("input", totals.input),
                ("output", totals.output),
                ("cache_read", totals.cacheRead),
                ("cache_write_5m", totals.cacheWrite5m),
                ("cache_write_1h", totals.cacheWrite1h),
            ]
            for (type, value) in byType {
                tokenPoints.append(.init(
                    attributes: [modelAttribute, .init("token.type", .string(type))],
                    startTime: start, time: now, value: .int(value)
                ))
            }
            messagePoints.append(.init(attributes: [modelAttribute], startTime: start, time: now, value: .int(totals.messages)))
            for (tool, value) in [("web_search", totals.webSearchRequests), ("web_fetch", totals.webFetchRequests)] {
                toolPoints.append(.init(
                    attributes: [modelAttribute, .init("tool", .string(tool))],
                    startTime: start, time: now, value: .int(value)
                ))
            }
        }
        return [
            .init(
                name: "bar.tokens", unit: "{token}",
                description: "Tokens Claude Code on this Mac sent and received, counted from its transcripts.",
                kind: .cumulativeSum, dataPoints: tokenPoints
            ),
            .init(
                name: "claude.code.messages", unit: "{message}",
                description: "Model responses Claude Code on this Mac received.",
                kind: .cumulativeSum, dataPoints: messagePoints
            ),
            .init(
                name: "claude.code.server_tool_requests", unit: "{request}",
                description: "Server-side tool calls (web search, web fetch) the model made.",
                kind: .cumulativeSum, dataPoints: toolPoints
            ),
        ]
    }

    // MARK: Observation and events

    /// What this stamp saw, merged over the previous observation: a part that couldn't be
    /// fetched this time keeps its last-known value, so a failed call doesn't read as the
    /// offer vanishing and then reappearing.
    public static func observe(usage: UsageResponse?, offers: AccountOffers, previous: ObservedState?) -> ObservedState {
        var observed = previous ?? ObservedState()
        if let usage {
            // Limits sharing a `limit.id` are ambiguous too, even when their keys differ (same
            // model ID, different display names): their events would be indistinguishable on
            // the wire, and their metrics are already left out for the same reason.
            let duplicateIDs = Set(Dictionary(grouping: usage.limits, by: limitID).filter { $0.value.count > 1 }.keys)
            let ambiguous = Set(
                Dictionary(grouping: usage.limits, by: \.celebrationKey)
                    .filter { $0.value.count > 1 }
                    .keys
            ).union(usage.limits.filter { duplicateIDs.contains(limitID($0)) }.map(\.celebrationKey))
            observed.ambiguousLimitKeys = ambiguous
            observed.limits = Dictionary(
                usage.limits.filter { !ambiguous.contains($0.celebrationKey) }.map { limit in
                    (limit.celebrationKey, ObservedState.Limit(
                        percent: limit.percent,
                        severity: limit.severity.rawValue,
                        resetsAt: limit.resetsAt,
                        attributes: Dictionary(uniqueKeysWithValues: limitAttributes(limit).compactMap { pair in
                            if case .string(let value) = pair.value { return (pair.key, value) }
                            return nil
                        })
                    ))
                },
                uniquingKeysWith: { first, _ in first }
            )
            if let extra = usage.extraUsage {
                observed.extraUsage = .init(isEnabled: extra.isEnabled, monthlyLimit: extra.monthlyLimit, usedCredits: extra.usedCredits)
            }
        }
        if let passes = offers.guestPasses { observed.offers.guestPasses = passes }
        if let grant = offers.creditGrant { observed.offers.creditGrant = grant }
        return observed
    }

    /// The event written when counting starts or restarts.
    public static func trackingStarted(now: Date, intervalMinutes: Int) -> OTLP.LogRecord {
        .init(
            time: now, eventName: "bar.tracking.started",
            body: "Tracking started, every \(intervalMinutes) minute\(intervalMinutes == 1 ? "" : "s")",
            attributes: [.init("tracking.interval_minutes", .int(Int64(intervalMinutes)))]
        )
    }

    /// Events for everything that changed between two observations. The first stamp ever
    /// (no previous) only seeds the baseline, the same rule celebrations follow.
    public static func events(previous: ObservedState?, current: ObservedState, now: Date) -> [OTLP.LogRecord] {
        guard let previous else { return [] }
        var events: [OTLP.LogRecord] = []

        if let before = previous.limits, let after = current.limits {
            // A key that's ambiguous on either side would compare different limits, or read
            // a limit dropping into ambiguity as it disappearing.
            let skipped = (previous.ambiguousLimitKeys ?? []).union(current.ambiguousLimitKeys ?? [])
            for key in after.keys.sorted() where !skipped.contains(key) {
                guard let limit = after[key] else { continue }
                let attributes = limitEventAttributes(key: key, limit: limit)
                guard let old = before[key] else {
                    events.append(.init(time: now, eventName: "bar.limit.appeared", body: "\(limitName(limit)) limit appeared", attributes: attributes))
                    continue
                }
                if windowRolledOver(from: old, to: limit, now: now) {
                    var resetAttributes = attributes + [.init("limit.utilization.last", .double(old.percent))]
                    if let next = limit.resetsAt {
                        resetAttributes.append(.init("limit.resets_at.next", .int(unixSeconds(next))))
                    }
                    events.append(.init(
                        time: now, eventName: "bar.limit.reset",
                        body: "\(limitName(limit)) reset from \(format(old.percent))% to \(format(limit.percent))%",
                        attributes: resetAttributes
                    ))
                }
                if old.severity != limit.severity {
                    events.append(.init(
                        time: now, eventName: "claude.limit.severity_changed",
                        body: "\(limitName(limit)) severity \(old.severity) → \(limit.severity)",
                        attributes: attributes + [
                            .init("previous_severity", .string(old.severity)),
                            .init("severity", .string(limit.severity)),
                        ]
                    ))
                }
            }
            for key in before.keys.sorted() where after[key] == nil && !skipped.contains(key) {
                guard let limit = before[key] else { continue }
                events.append(.init(
                    time: now, eventName: "bar.limit.disappeared",
                    body: "\(limitName(limit)) limit disappeared",
                    attributes: limitEventAttributes(key: key, limit: limit)
                ))
            }
        }

        if let before = previous.extraUsage?.isEnabled, let after = current.extraUsage?.isEnabled, before != after {
            events.append(.init(
                time: now, eventName: "claude.extra_usage.enabled_changed",
                body: "Extra usage switched \(after ? "on" : "off")",
                attributes: [.init("enabled", .bool(after))]
            ))
        }

        events.append(contentsOf: guestPassEvents(
            before: previous.offers.guestPasses, after: current.offers.guestPasses, now: now
        ))
        events.append(contentsOf: creditGrantEvents(
            before: previous.offers.creditGrant, after: current.offers.creditGrant, now: now
        ))
        return events
    }

    /// A window rolled over when the old one has ended and the API now reports a later end.
    /// The usage-drop rule celebrations use also counts: it's the only signal without reset
    /// times, and it still catches a rollover the timestamps hid (the API moving the end
    /// forward before the old one passed leaves both stamps showing the same end).
    static func windowRolledOver(from old: ObservedState.Limit, to new: ObservedState.Limit, now: Date) -> Bool {
        if let oldEnd = old.resetsAt, let newEnd = new.resetsAt,
           newEnd.timeIntervalSince(oldEnd) > windowRolloverTolerance,
           now.timeIntervalSince(oldEnd) >= -windowRolloverTolerance {
            return true
        }
        return usageDidReset(from: old.percent, to: new.percent)
    }

    private static func guestPassEvents(before: GuestPassStatus?, after: GuestPassStatus?, now: Date) -> [OTLP.LogRecord] {
        // No earlier successful fetch means the previous count is unknown, not zero; the
        // first value seen is only a baseline.
        guard let before, let after else { return [] }
        let was = availablePasses(before)
        let available = availablePasses(after)
        let attributes = guestPassAttributes(after) + [
            .init("perk.quantity", .int(Int64(abs(available - was)))),
            .init("claude.previous_available", .int(Int64(was))),
            .init("claude.available", .int(Int64(available))),
        ]
        if available > was {
            return [.init(
                time: now, eventName: "bar.perk.available",
                body: "\(available - was) guest pass\(available - was == 1 ? "" : "es") became available (\(available) to share)",
                attributes: attributes
            )]
        }
        if available < was {
            // A count that drops while the account is still eligible is passes being redeemed.
            // Losing eligibility outright could be the campaign ending or anything else, so no
            // reason is claimed and Bar UI works it out.
            let used = after.eligible
            return [.init(
                time: now, eventName: "bar.perk.gone",
                body: "\(was - available) guest pass\(was - available == 1 ? "" : "es") \(used ? "redeemed" : "no longer offered") (\(available) left)",
                attributes: attributes + (used ? [.init("perk.gone.reason", .string("used"))] : [])
            )]
        }
        return []
    }

    private static func creditGrantEvents(before: CreditGrantStatus?, after: CreditGrantStatus?, now: Date) -> [OTLP.LogRecord] {
        guard let before, let after else { return [] }
        // The amount and currency can drop out of a later response; the earlier ones still
        // describe the same grant.
        let merged = CreditGrantStatus(
            campaign: after.campaign,
            available: after.available,
            eligible: after.eligible,
            granted: after.granted,
            amountMinorUnits: after.amountMinorUnits ?? before.amountMinorUnits,
            currency: after.currency ?? before.currency
        )
        var attributes: [OTLP.KeyValue] = creditGrantAttributes(merged) ?? [
            .init("perk.kind", .string("credit_grant")),
            .init("claude.campaign", .string(merged.campaign)),
        ]
        // A grant is claimed whole, so each event moves its full amount. Without a known amount
        // the quantity is left out rather than letting Bar UI read the default 1 as a value.
        if let currency = merged.currency, !currency.isEmpty, let minor = merged.amountMinorUnits {
            attributes.append(.init("perk.quantity", .double(majorUnits(minor, currency: currency))))
        }

        if after.isClaimable && !before.isClaimable {
            return [.init(time: now, eventName: "bar.perk.available", body: "Promotional credit available to claim", attributes: attributes)]
        }
        if before.isClaimable && !after.isClaimable {
            // Only a grant the API marks as granted is known to have been claimed.
            let used = after.granted
            return [.init(
                time: now, eventName: "bar.perk.gone",
                body: "Promotional credit \(used ? "claimed" : "no longer offered")",
                attributes: attributes + (used ? [.init("perk.gone.reason", .string("used"))] : [])
            )]
        }
        return []
    }

    // MARK: Helpers

    /// The spec's stable Limit ID: the API's `kind`, plus the model it's scoped to. A scoped
    /// limit with no model ID falls back to its display name, which is still better than
    /// colliding with every other scoped limit of the same kind.
    static func limitID(_ limit: UsageLimit) -> String {
        limitID(kind: limit.kind, modelID: limit.scope?.model?.id, modelName: limit.scope?.model?.displayName)
    }

    private static func limitID(kind: String, modelID: String?, modelName: String?) -> String {
        if let modelID, !modelID.isEmpty { return "\(kind):\(modelID)" }
        if let modelName, !modelName.isEmpty { return "\(kind):\(modelName)" }
        return kind
    }

    static func limitAttributes(_ limit: UsageLimit) -> [OTLP.KeyValue] {
        var attributes: [OTLP.KeyValue] = [
            .init("limit.id", .string(limitID(limit))),
            .init("limit.name", .string(LimitPresentation.displayName(for: limit))),
        ]
        if let minutes = windowMinutes(group: limit.group) {
            attributes.append(.init("limit.window.duration_minutes", .int(minutes)))
        }
        if let id = limit.scope?.model?.id, !id.isEmpty { attributes.append(.init("model.id", .string(id))) }
        attributes.append(.init("limit.kind", .string(limit.kind)))
        if let group = limit.group { attributes.append(.init("limit.group", .string(group))) }
        if let name = limit.scope?.model?.displayName, !name.isEmpty { attributes.append(.init("model.name", .string(name))) }
        return attributes
    }

    /// Limit attributes for an event, rebuilt from what was observed. The ID comes from the
    /// observation key rather than a stored attribute, so state saved by an older version
    /// (which had no `limit.id`) still produces a conforming event.
    private static func limitEventAttributes(key: String, limit: ObservedState.Limit) -> [OTLP.KeyValue] {
        let parts = key.split(separator: "\u{1}", omittingEmptySubsequences: false).map(String.init)
        let kind = parts.first ?? limit.attributes["limit.kind"] ?? "unknown"
        let modelID = parts.count > 1 ? parts[1] : nil
        let modelName = parts.count > 2 ? parts[2] : nil

        var attributes: [OTLP.KeyValue] = [
            .init("limit.id", .string(limitID(kind: kind, modelID: modelID, modelName: modelName))),
            .init("limit.name", .string(limitName(limit))),
        ]
        if let minutes = windowMinutes(group: limit.attributes["limit.group"]) {
            attributes.append(.init("limit.window.duration_minutes", .int(minutes)))
        }
        if let modelID, !modelID.isEmpty { attributes.append(.init("model.id", .string(modelID))) }
        attributes.append(.init("limit.kind", .string(kind)))
        if let group = limit.attributes["limit.group"] { attributes.append(.init("limit.group", .string(group))) }
        if let modelName, !modelName.isEmpty { attributes.append(.init("model.name", .string(modelName))) }
        return attributes
    }

    private static func windowMinutes(group: String?) -> Int64? {
        UsageWindow.duration(forGroup: group).map { Int64(($0 / 60).rounded()) }
    }

    private static func availablePasses(_ passes: GuestPassStatus) -> Int {
        passes.eligible ? (passes.remaining ?? 0) : 0
    }

    private static func guestPassAttributes(_ passes: GuestPassStatus) -> [OTLP.KeyValue] {
        [.init("perk.kind", .string("guest_pass")), .init("claude.campaign", .string(passes.campaign))]
    }

    /// nil when the currency is unknown, since the spec requires it for a credit grant.
    private static func creditGrantAttributes(_ grant: CreditGrantStatus) -> [OTLP.KeyValue]? {
        guard let currency = grant.currency, !currency.isEmpty else { return nil }
        return [
            .init("perk.kind", .string("credit_grant")),
            .init("perk.currency", .string(currency.uppercased())),
            .init("claude.campaign", .string(grant.campaign)),
        ]
    }

    /// The grant's value in major units while it can still be claimed, 0 once it can't.
    /// nil when it's claimable but the amount or currency is unknown.
    private static func availableGrantAmount(_ grant: CreditGrantStatus) -> Double? {
        guard grant.isClaimable else { return 0 }
        guard let minor = grant.amountMinorUnits, let currency = grant.currency, !currency.isEmpty else { return nil }
        return majorUnits(minor, currency: currency)
    }

    /// Converts minor units (cents) to major units using the currency's ISO 4217 exponent:
    /// 2 for USD, 0 for JPY, 3 for KWD.
    static func majorUnits(_ minor: Int64, currency: String) -> Double {
        let exponent = currencyExponent(currency)
        return Double(minor) / pow(10, Double(exponent))
    }

    static func currencyExponent(_ currency: String) -> Int {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.currencyCode = currency.uppercased()
        return formatter.maximumFractionDigits
    }

    private static func limitName(_ limit: ObservedState.Limit) -> String {
        limit.attributes["limit.name"] ?? limit.attributes["limit.kind"] ?? "Limit"
    }

    private static func unixSeconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.down))
    }

    private static func format(_ percent: Double) -> String {
        percent.rounded() == percent ? String(Int(percent)) : String(format: "%.1f", percent)
    }

    private static func gauge(_ name: String, unit: String, _ description: String, _ points: [OTLP.NumberDataPoint]) -> OTLP.Metric {
        OTLP.Metric(name: name, unit: unit, description: description, kind: .gauge, dataPoints: points)
    }

    private static func point(_ attributes: [OTLP.KeyValue], _ time: Date, _ value: OTLP.NumberDataPoint.Value) -> OTLP.NumberDataPoint {
        OTLP.NumberDataPoint(attributes: attributes, time: time, value: value)
    }
}
