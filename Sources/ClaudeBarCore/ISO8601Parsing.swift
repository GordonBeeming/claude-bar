import Foundation

/// Parses the API's `resets_at` timestamps, which arrive as ISO8601 with 6-digit
/// fractional seconds (e.g. `2026-07-07T06:20:00.010527+00:00`) — a precision
/// `Date.ISO8601FormatStyle` doesn't accept directly, so we fall back to truncating.
public enum ISO8601Parsing {
    public static func parse(_ string: String) -> Date? {
        let withFractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let date = try? withFractionalSeconds.parse(string) {
            return date
        }

        let withoutFractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
        if let date = try? withoutFractionalSeconds.parse(string) {
            return date
        }

        if let truncated = truncatingFractionalSeconds(string, to: 3),
           let date = try? withFractionalSeconds.parse(truncated) {
            return date
        }

        return nil
    }

    /// `ISO8601FormatStyle` only accepts millisecond precision, so a 6-digit (or
    /// otherwise longer) fraction needs shortening before a second parse attempt.
    private static func truncatingFractionalSeconds(_ string: String, to digits: Int) -> String? {
        guard let range = string.range(of: #"\.\d+"#, options: .regularExpression) else {
            return nil
        }

        let fractionDigits = string[range].dropFirst() // drop the leading "."
        guard fractionDigits.count > digits else {
            return nil
        }

        let truncated = "." + fractionDigits.prefix(digits)
        return string.replacingCharacters(in: range, with: truncated)
    }
}
