import CryptoKit
import Foundation

/// One Claude Code sign-in ClaudeBar watches: a config folder (`~/.claude`, or whatever
/// `CLAUDE_CONFIG_DIR` points a second account at) plus everything derived from it.
public struct ClaudeAccount: Identifiable, Hashable, Sendable {
    /// The id of the `~/.claude` account. Reserved: no other folder can take it.
    public static let defaultID = "default"

    private static let keychainServiceBase = "Claude Code-credentials"
    private static let selfContainedServiceBase = "com.gordonbeeming.ClaudeBar.oauth"
    private static let telemetryServiceBase = "claudebar"

    /// Stable and safe in a file name, a defaults key and a Keychain service suffix.
    public let id: String
    public let configDir: URL
    public let isDefault: Bool
    /// Where Claude Code keeps this account's profile (`oauthAccount`). The default account's
    /// lives at the home root rather than inside `~/.claude`.
    public let profileURL: URL
    public var email: String?
    public var organization: String?

    public init(
        id: String,
        configDir: URL,
        isDefault: Bool,
        profileURL: URL,
        email: String? = nil,
        organization: String? = nil
    ) {
        self.id = id
        self.configDir = configDir
        self.isDefault = isDefault
        self.profileURL = profileURL
        self.email = email
        self.organization = organization
    }

    /// The `~/.claude` account for a given home.
    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ClaudeAccount {
        ClaudeAccount(
            id: defaultID,
            configDir: home.appending(path: ".claude", directoryHint: .isDirectory),
            isDefault: true,
            profileURL: home.appending(path: ".claude.json")
        )
    }

    /// Claude Code names the Keychain item after the config folder so accounts don't share one:
    /// the plain name for `~/.claude`, otherwise a suffix of the first 8 hex characters of the
    /// SHA-256 of the folder's absolute path with no trailing slash.
    public var keychainService: String {
        guard !isDefault else { return Self.keychainServiceBase }
        let digest = SHA256.hash(data: Data(Self.pathString(configDir).utf8))
        let suffix = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        return "\(Self.keychainServiceBase)-\(suffix)"
    }

    /// The default account keeps today's name so existing sign-ins carry over.
    public var selfContainedService: String {
        isDefault ? Self.selfContainedServiceBase : "\(Self.selfContainedServiceBase).\(id)"
    }

    public var credentialsFileURL: URL {
        configDir.appending(path: ".credentials.json")
    }

    public var transcriptsRoot: URL {
        configDir.appending(path: "projects", directoryHint: .isDirectory)
    }

    /// The `service.name` in file names for this account's telemetry. The resource attribute of
    /// the same name stays `claudebar` for every account; only the files are told apart.
    public var telemetryFileServiceName: String {
        isDefault ? Self.telemetryServiceBase : "\(Self.telemetryServiceBase).\(id)"
    }

    public var telemetryStateFileName: String {
        isDefault ? "telemetry-state.json" : "telemetry-state.\(id).json"
    }

    /// The account as a self-contained sign-in sees it. That sign-in can be a different person
    /// from the one Claude Code is signed in as in this folder, so the profile's email would
    /// mislabel it; when the sign-in recorded no identity, no email is better than a wrong one.
    public func withIdentity(email: String?, organization: String?) -> ClaudeAccount {
        var copy = self
        copy.email = email
        copy.organization = organization
        return copy
    }

    /// What to call the account in the UI: the email when known, else the folder name.
    public var displayName: String {
        if let email, !email.isEmpty { return email }
        return isDefault ? "Default" : configDir.lastPathComponent
    }

    /// Lowercases, replaces every character outside `[a-z0-9-]` with `-`, collapses runs and
    /// trims the ends. Can return an empty string; the caller resolves that.
    public static func sanitizedID(fromFolderName name: String) -> String {
        var result = ""
        var lastWasDash = false
        for scalar in name.lowercased().unicodeScalars {
            let isAllowed = (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9")
            if isAllowed {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func pathString(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
