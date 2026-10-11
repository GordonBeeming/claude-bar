import Foundation

/// Root shape of `GET /api/oauth/usage` — a flat list of limits, self-describing by `kind`.
public struct UsageResponse: Decodable, Sendable {
    public let limits: [UsageLimit]
    /// Pay-as-you-go credit state. nil when the API omits it or sends a shape we can't read.
    public let extraUsage: ExtraUsage?

    public init(limits: [UsageLimit], extraUsage: ExtraUsage? = nil) {
        self.limits = limits
        self.extraUsage = extraUsage
    }

    private enum CodingKeys: String, CodingKey {
        case limits
        case extraUsage = "extra_usage"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limits = try container.decode([UsageLimit].self, forKey: .limits)
        // Only telemetry reads this, so a shape change must never cost the menu its limits.
        extraUsage = try? container.decodeIfPresent(ExtraUsage.self, forKey: .extraUsage)
    }
}

/// The `extra_usage` block of the usage response. Every field is optional because the API
/// sends nulls for anything that doesn't apply (e.g. no monthly limit when it's switched off).
/// Credit amounts are passed through as the API reports them; `decimalPlaces` says how to scale.
public struct ExtraUsage: Decodable, Sendable, Equatable {
    public let isEnabled: Bool?
    public let monthlyLimit: Double?
    public let usedCredits: Double?
    public let utilization: Double?
    public let currency: String?
    public let decimalPlaces: Int?
    public let disabledReason: String?
    public let spendLimitReached: Bool?

    public init(
        isEnabled: Bool? = nil,
        monthlyLimit: Double? = nil,
        usedCredits: Double? = nil,
        utilization: Double? = nil,
        currency: String? = nil,
        decimalPlaces: Int? = nil,
        disabledReason: String? = nil,
        spendLimitReached: Bool? = nil
    ) {
        self.isEnabled = isEnabled
        self.monthlyLimit = monthlyLimit
        self.usedCredits = usedCredits
        self.utilization = utilization
        self.currency = currency
        self.decimalPlaces = decimalPlaces
        self.disabledReason = disabledReason
        self.spendLimitReached = spendLimitReached
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
        case currency
        case decimalPlaces = "decimal_places"
        case disabledReason = "disabled_reason"
        case spendLimitReached = "spend_limit_reached"
    }
}

/// One usage limit bucket (e.g. the 5h session window, or a weekly window scoped to a model).
public struct UsageLimit: Decodable, Sendable, Identifiable {
    public let kind: String
    public let group: String?
    public let percent: Double
    public let severity: Severity
    public let resetsAt: Date?
    public let scope: LimitScope?
    public let isActive: Bool

    // Model-scoped limits share a `kind` (e.g. "weekly_scoped") across models, so the
    // scoped display name disambiguates them for SwiftUI's ForEach identity.
    public var id: String {
        kind + (scope?.model?.displayName ?? "")
    }

    // A stronger identity for celebration snapshots than `id`: two scoped limits with no
    // display name collapse to the same `id`, which let a high-% previous snapshot get
    // compared against a different low-% current limit and fire a phantom reset. Folding in
    // the model id (and a separator) keeps distinct models apart; the SOH separator can't
    // appear in a kind/id/name, so keys never alias by concatenation. When two limits are
    // still identical here they're genuinely indistinguishable — the detector skips those.
    public var celebrationKey: String {
        [kind, scope?.model?.id ?? "", scope?.model?.displayName ?? ""].joined(separator: "\u{1}")
    }

    public var selectionKey: String {
        let modelID = scope?.model?.id
        let modelKey: String
        if let modelID, !modelID.isEmpty {
            modelKey = modelID
        } else {
            modelKey = scope?.model?.displayName ?? ""
        }
        return [kind, modelKey].joined(separator: "\u{1}")
    }

    public init(
        kind: String,
        group: String? = nil,
        percent: Double,
        severity: Severity,
        resetsAt: Date? = nil,
        scope: LimitScope? = nil,
        isActive: Bool = false
    ) {
        self.kind = kind
        self.group = group
        self.percent = percent
        self.severity = severity
        self.resetsAt = resetsAt
        self.scope = scope
        self.isActive = isActive
    }

    private enum CodingKeys: String, CodingKey {
        case kind, group, percent, severity, scope
        case resetsAt = "resets_at"
        case isActive = "is_active"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        group = try container.decodeIfPresent(String.self, forKey: .group)

        // The API has been observed sending percent as a bare integer as well as a
        // decimal; try both rather than trusting one shape.
        if let doubleValue = try? container.decode(Double.self, forKey: .percent) {
            percent = doubleValue
        } else if let intValue = try? container.decode(Int.self, forKey: .percent) {
            percent = Double(intValue)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .percent,
                in: container,
                debugDescription: "percent was neither a Double nor an Int"
            )
        }

        severity = try container.decodeIfPresent(Severity.self, forKey: .severity) ?? .normal

        if let resetsAtString = try container.decodeIfPresent(String.self, forKey: .resetsAt) {
            resetsAt = ISO8601Parsing.parse(resetsAtString)
        } else {
            resetsAt = nil
        }

        scope = try container.decodeIfPresent(LimitScope.self, forKey: .scope)
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
    }
}

/// The model a limit is scoped to, when it isn't an all-models limit.
public struct LimitScope: Decodable, Sendable {
    public let model: Model?

    public struct Model: Decodable, Sendable {
        public let id: String?
        public let displayName: String?

        private enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
        }

        public init(id: String? = nil, displayName: String? = nil) {
            self.id = id
            self.displayName = displayName
        }
    }

    public init(model: Model? = nil) {
        self.model = model
    }

    private enum CodingKeys: String, CodingKey {
        case model
    }
}

public enum Severity: String, Decodable, Sendable, Comparable {
    case normal
    case warning
    case critical

    // Unknown severities (a future API addition, a typo'd fixture) degrade to
    // `.normal` rather than failing the whole decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = Severity(rawValue: raw) ?? .normal
    }

    private var ordinal: Int {
        switch self {
        case .normal: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }

    public static func < (lhs: Severity, rhs: Severity) -> Bool {
        lhs.ordinal < rhs.ordinal
    }
}

/// The limit to lead with in the menu bar icon: highest usage first, ties broken by severity.
public func highestLimit(in limits: [UsageLimit]) -> UsageLimit? {
    limits.max { lhs, rhs in
        if lhs.percent != rhs.percent {
            return lhs.percent < rhs.percent
        }
        return lhs.severity < rhs.severity
    }
}

public func menuBarLimit(in limits: [UsageLimit], selectedKey: String?) -> UsageLimit? {
    let highest = highestLimit(in: limits)
    guard let selectedKey else { return highest }
    return limits.first { $0.selectionKey == selectedKey } ?? highest
}
