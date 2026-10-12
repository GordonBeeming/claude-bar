import Foundation

/// A `claudebar://` URL another app (Bar UI, say) opened, as the Bar Telemetry Spec defines
/// it. Parsing is all-or-nothing: one bad value rejects the whole request, so a typo can't
/// half-apply a change.
public enum ClaudeBarURLRequest: Equatable, Sendable {
    case telemetry(TelemetryChange)
    case openSettings

    public static let scheme = "claudebar"

    /// The settings a `telemetry` request asks for. A nil field leaves that setting alone.
    public struct TelemetryChange: Equatable, Sendable {
        public var enabled: Bool?
        public var intervalMinutes: Int?
        /// 0 is "keep forever".
        public var retentionDays: Int?
        public var folder: URL?

        public init(enabled: Bool? = nil, intervalMinutes: Int? = nil, retentionDays: Int? = nil, folder: URL? = nil) {
            self.enabled = enabled
            self.intervalMinutes = intervalMinutes
            self.retentionDays = retentionDays
            self.folder = folder
        }

        public var isEmpty: Bool {
            enabled == nil && intervalMinutes == nil && retentionDays == nil && folder == nil
        }
    }

    public enum ParseError: Error, Equatable, Sendable, LocalizedError {
        case wrongScheme(String?)
        case unknownAction(String)
        case invalidValue(parameter: String, value: String, expected: String)

        public var errorDescription: String? {
            switch self {
            case .wrongScheme(let scheme):
                "The link uses \(scheme.map { "“\($0)://”" } ?? "no scheme"), not claudebar://."
            case .unknownAction(let action):
                "ClaudeBar doesn't know the action “\(action)”. It understands claudebar://telemetry and claudebar://settings."
            case .invalidValue(let parameter, let value, let expected):
                "“\(value)” isn't a valid \(parameter). Expected \(expected)."
            }
        }
    }

    public static func parse(_ url: URL) throws(ParseError) -> ClaudeBarURLRequest {
        guard url.scheme?.lowercased() == scheme else { throw .wrongScheme(url.scheme) }
        // `claudebar://telemetry` puts the action in the host; `claudebar:telemetry` in the path.
        let action = (url.host() ?? url.path(percentEncoded: false))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        switch action {
        case "settings":
            return .openSettings
        case "telemetry":
            return .telemetry(try parseTelemetry(url))
        default:
            throw .unknownAction(action)
        }
    }

    private static func parseTelemetry(_ url: URL) throws(ParseError) -> TelemetryChange {
        var change = TelemetryChange()
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // Unknown parameters are ignored, as the spec asks, so a newer Bar UI can send more.
        for item in items {
            let value = item.value ?? ""
            switch item.name {
            case "enabled":
                switch value.lowercased() {
                case "1", "true": change.enabled = true
                case "0", "false": change.enabled = false
                default: throw .invalidValue(parameter: "enabled", value: value, expected: "1, 0, true or false")
                }
            case "interval":
                let range = TelemetryConfig.intervalMinutesRange
                guard let minutes = Int(value), range.contains(minutes) else {
                    throw .invalidValue(
                        parameter: "interval", value: value,
                        expected: "a whole number of minutes from \(range.lowerBound) to \(range.upperBound)"
                    )
                }
                change.intervalMinutes = minutes
            case "retention":
                let range = TelemetryConfig.retentionDaysRange
                guard let days = Int(value), range.contains(days) else {
                    throw .invalidValue(
                        parameter: "retention", value: value,
                        expected: "a whole number of days from \(range.lowerBound) (forever) to \(range.upperBound)"
                    )
                }
                change.retentionDays = days
            case "folder":
                // URLComponents has already percent-decoded the value.
                let path = (value as NSString).expandingTildeInPath
                guard path.hasPrefix("/") else {
                    throw .invalidValue(parameter: "folder", value: value, expected: "an absolute path")
                }
                change.folder = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
            default:
                continue
            }
        }
        return change
    }
}
