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

/// Builds one stamp's metrics and events from what the app currently knows. Pure, so the
/// whole mapping is unit-tested without a clock, network, or disk.
public enum TelemetryStamp {
    /// Points a limit has to fall, without its window resetting, before an offer that
    /// disappeared at the same time is read as having been used rather than expiring.
    static let usedDropThreshold = 10.0

    // MARK: Metrics

    public static func metrics(
        usage: UsageResponse?,
        offers: AccountOffers,
        tokens: TranscriptScanState?,
        now: Date
    ) -> [OTLP.Metric] {
        var metrics: [OTLP.Metric] = []

        if let usage, !usage.limits.isEmpty {
            let limits = usage.limits.map { (limit: $0, attributes: limitAttributes($0)) }
            metrics.append(gauge(
                "claude.usage.limit.utilization", unit: "%",
                "Share of the limit's allowance used in its current window.",
                limits.map { point($0.attributes, now, .double($0.limit.percent)) }
            ))
            metrics.append(gauge(
                "claude.usage.limit.resets_at", unit: "s",
                "When the limit's current window ends, as Unix seconds.",
                limits.compactMap { entry in
                    entry.limit.resetsAt.map { point(entry.attributes, now, .int(Int64($0.timeIntervalSince1970))) }
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

        if let passes = offers.guestPasses {
            let attributes = [OTLP.KeyValue("campaign", .string(passes.campaign))]
            metrics.append(gauge(
                "claude.guest_passes.available", unit: "{pass}",
                "Guest passes the account can still hand out.",
                [point(attributes, now, .int(Int64(passes.eligible ? (passes.remaining ?? 0) : 0)))]
            ))
            if let limit = passes.limit {
                metrics.append(gauge(
                    "claude.guest_passes.limit", unit: "{pass}",
                    "Guest passes the account gets in total.",
                    [point(attributes, now, .int(Int64(limit)))]
                ))
            }
        }

        if let grant = offers.creditGrant {
            var attributes = [OTLP.KeyValue("campaign", .string(grant.campaign))]
            if let currency = grant.currency { attributes.append(.init("currency", .string(currency))) }
            metrics.append(gauge(
                "claude.credit_grant.available", unit: "1",
                "1 while a promotional extra-usage credit is offered and unclaimed.",
                [point(attributes, now, .int(grant.isClaimable ? 1 : 0))]
            ))
            if let amount = grant.amountMinorUnits {
                metrics.append(gauge(
                    "claude.credit_grant.amount", unit: "{minor_unit}",
                    "Value of the offered credit in the currency's minor units (cents).",
                    [point(attributes, now, .int(amount))]
                ))
            }
        }

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
                name: "claude.code.tokens", unit: "{token}",
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
            let ambiguous = Set(
                Dictionary(grouping: usage.limits, by: \.celebrationKey)
                    .filter { $0.value.count > 1 }
                    .keys
            )
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
                let attributes = stringAttributes(limit.attributes)
                guard let old = before[key] else {
                    events.append(.init(time: now, eventName: "limit.appeared", body: "\(limitName(limit)) limit appeared", attributes: attributes))
                    continue
                }
                if usageDidReset(from: old.percent, to: limit.percent) {
                    events.append(.init(
                        time: now, eventName: "limit.reset",
                        body: "\(limitName(limit)) reset from \(format(old.percent))% to \(format(limit.percent))%",
                        attributes: attributes + [
                            .init("previous_percent", .double(old.percent)),
                            .init("percent", .double(limit.percent)),
                        ]
                    ))
                }
                if old.severity != limit.severity {
                    events.append(.init(
                        time: now, eventName: "limit.severity_changed",
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
                    time: now, eventName: "limit.disappeared",
                    body: "\(limitName(limit)) limit disappeared",
                    attributes: stringAttributes(limit.attributes)
                ))
            }
        }

        if let before = previous.extraUsage?.isEnabled, let after = current.extraUsage?.isEnabled, before != after {
            events.append(.init(
                time: now, eventName: "extra_usage.enabled_changed",
                body: "Extra usage switched \(after ? "on" : "off")",
                attributes: [.init("enabled", .bool(after))]
            ))
        }

        events.append(contentsOf: guestPassEvents(
            before: previous.offers.guestPasses, after: current.offers.guestPasses, now: now
        ))
        events.append(contentsOf: creditGrantEvents(previous: previous, current: current, now: now))
        return events
    }

    private static func guestPassEvents(before: GuestPassStatus?, after: GuestPassStatus?, now: Date) -> [OTLP.LogRecord] {
        guard let after else { return [] }
        let was = before.map { $0.eligible ? ($0.remaining ?? 0) : 0 } ?? 0
        let available = after.eligible ? (after.remaining ?? 0) : 0
        let attributes: [OTLP.KeyValue] = [
            .init("campaign", .string(after.campaign)),
            .init("previous_available", .int(Int64(was))),
            .init("available", .int(Int64(available))),
        ]
        if available > was {
            return [.init(
                time: now, eventName: "guest_pass.available",
                body: "\(available - was) guest pass\(available - was == 1 ? "" : "es") became available (\(available) to share)",
                attributes: attributes
            )]
        }
        if available < was {
            // Losing eligibility outright isn't someone redeeming a pass; the passes just
            // stopped being offered.
            let reason = after.eligible ? "used" : "expired"
            return [.init(
                time: now, eventName: "guest_pass.gone",
                body: "\(was - available) guest pass\(was - available == 1 ? "" : "es") \(reason == "used" ? "redeemed" : "no longer offered") (\(available) left)",
                attributes: attributes + [.init("inferred_reason", .string(reason))]
            )]
        }
        return []
    }

    private static func creditGrantEvents(previous: ObservedState, current: ObservedState, now: Date) -> [OTLP.LogRecord] {
        guard let after = current.offers.creditGrant else { return [] }
        let wasClaimable = previous.offers.creditGrant?.isClaimable ?? false
        var attributes: [OTLP.KeyValue] = [.init("campaign", .string(after.campaign))]
        if let amount = after.amountMinorUnits ?? previous.offers.creditGrant?.amountMinorUnits {
            attributes.append(.init("amount_minor_units", .int(amount)))
        }
        if let currency = after.currency ?? previous.offers.creditGrant?.currency {
            attributes.append(.init("currency", .string(currency)))
        }

        if after.isClaimable && !wasClaimable {
            return [.init(time: now, eventName: "credit_grant.available", body: "Promotional credit available to claim", attributes: attributes)]
        }
        if wasClaimable && !after.isClaimable {
            let reason = after.granted || usageSuggestsRedemption(previous: previous, current: current) ? "used" : "expired"
            return [.init(
                time: now, eventName: "credit_grant.gone",
                body: "Promotional credit \(reason == "used" ? "claimed" : "no longer offered")",
                attributes: attributes + [.init("inferred_reason", .string(reason))]
            )]
        }
        return []
    }

    /// Redeeming credit shows up as headroom: the extra-usage cap goes up, or a limit's usage
    /// falls without its window rolling over. Neither happening means the offer most likely
    /// just ran out.
    static func usageSuggestsRedemption(previous: ObservedState, current: ObservedState) -> Bool {
        if let before = previous.extraUsage?.monthlyLimit, let after = current.extraUsage?.monthlyLimit, after > before {
            return true
        }
        if let before = previous.extraUsage?.isEnabled, let after = current.extraUsage?.isEnabled, !before && after {
            return true
        }
        guard let beforeLimits = previous.limits, let afterLimits = current.limits else { return false }
        for (key, after) in afterLimits {
            guard let before = beforeLimits[key] else { continue }
            let sameWindow = before.resetsAt == after.resetsAt
            if sameWindow && before.percent - after.percent >= usedDropThreshold {
                return true
            }
        }
        return false
    }

    // MARK: Helpers

    static func limitAttributes(_ limit: UsageLimit) -> [OTLP.KeyValue] {
        var attributes: [OTLP.KeyValue] = [
            .init("limit.kind", .string(limit.kind)),
            .init("limit.name", .string(LimitPresentation.displayName(for: limit))),
        ]
        if let group = limit.group { attributes.append(.init("limit.group", .string(group))) }
        if let id = limit.scope?.model?.id, !id.isEmpty { attributes.append(.init("model.id", .string(id))) }
        if let name = limit.scope?.model?.displayName, !name.isEmpty { attributes.append(.init("model.name", .string(name))) }
        attributes.append(.init("severity", .string(limit.severity.rawValue)))
        attributes.append(.init("is_active", .bool(limit.isActive)))
        return attributes
    }

    private static func stringAttributes(_ attributes: [String: String]) -> [OTLP.KeyValue] {
        attributes.keys.sorted().compactMap { key in
            // Severity is reported on its own in the events that care about it; a stale copy
            // here would contradict the event's own before/after fields.
            guard key != "severity", let value = attributes[key] else { return nil }
            return .init(key, .string(value))
        }
    }

    private static func limitName(_ limit: ObservedState.Limit) -> String {
        limit.attributes["limit.name"] ?? limit.attributes["limit.kind"] ?? "Limit"
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
