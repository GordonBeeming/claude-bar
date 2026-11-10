import Foundation

/// What the app says about which build it is. Reads the Info.plist values the Makefile stamps:
/// `GBDisplayVersion` carries the full string ("0.13 (172)" for a release, "0.13-dev (abc1234)"
/// for a local build), while `CFBundleShortVersionString` stays numeric for macOS.
public enum AppVersion {
    static let displayKey = "GBDisplayVersion"

    /// The full string, for Settings and tooltips: `GBDisplayVersion`, else "Short (Build)",
    /// else just the short version, else "dev" (a bare `swift run` has no Info.plist).
    public static func display(from info: [String: Any]) -> String {
        if let display = nonEmpty(info[displayKey]) { return display }
        guard let short = nonEmpty(info["CFBundleShortVersionString"]) else { return "dev" }
        guard let build = nonEmpty(info["CFBundleVersion"]) else { return short }
        return "\(short) (\(build))"
    }

    /// The compact form for the menu: "v0.13", or "v0.13-dev" for a local build.
    public static func short(from info: [String: Any]) -> String {
        guard let short = nonEmpty(info["CFBundleShortVersionString"]) else { return "dev" }
        let isDev = nonEmpty(info[displayKey])?.contains("-dev") ?? false
        return "v\(short)\(isDev ? "-dev" : "")"
    }

    public static var currentDisplay: String { display(from: Bundle.main.infoDictionary ?? [:]) }
    public static var currentShort: String { short(from: Bundle.main.infoDictionary ?? [:]) }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}
