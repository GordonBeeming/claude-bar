import Foundation
import os

/// Finds the Claude Code accounts on this Mac: `~/.claude`, every `~/.claude-accounts/*`
/// folder that holds a `.claude.json`, and any folder the person added by hand.
public enum ClaudeAccountDiscovery {
    private static let logger = Logger(subsystem: "com.gordonbeeming.ClaudeBar", category: "AccountDiscovery")

    public struct Result: Sendable, Equatable {
        public let accounts: [ClaudeAccount]
        /// Every folder-path-to-id assignment known after this run: the ones passed in plus
        /// any made now. The caller persists it so an id never moves to another folder.
        public let idsByPath: [String: String]
    }

    /// An id is chosen once, the first time a folder is seen, and `knownIDs` keeps it there:
    /// ids derive from Keychain items, telemetry files and settings, so they must not shift
    /// when another folder is added or removed. An id stays reserved for its folder even while
    /// that folder is missing.
    public static func discover(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        extraFolders: [URL] = [],
        knownIDs: [String: String] = [:]
    ) -> Result {
        var accounts = [ClaudeAccount.standard(home: home)]
        var seenPaths: Set<String> = [resolvedPath(accounts[0].configDir)]
        var ids = knownIDs
        var usedIDs = Set(knownIDs.values).union([ClaudeAccount.defaultID])

        func add(folder: URL) {
            let key = resolvedPath(folder)
            guard seenPaths.insert(key).inserted else { return }
            let id: String
            if let known = ids[key] {
                id = known
            } else {
                id = uniqueID(forFolderName: folder.lastPathComponent, used: usedIDs)
                ids[key] = id
                usedIDs.insert(id)
            }
            accounts.append(ClaudeAccount(
                id: id,
                configDir: folder.standardizedFileURL,
                isDefault: false,
                profileURL: folder.appending(path: ".claude.json")
            ))
        }

        let container = home.appending(path: ".claude-accounts", directoryHint: .isDirectory)
        for folder in subfolders(of: container) where hasProfile(folder) {
            add(folder: folder)
        }
        for folder in extraFolders {
            guard isUsableDirectory(folder) else {
                logger.notice("skipping extra account folder: not a readable, non-symlink directory")
                continue
            }
            add(folder: folder)
        }

        let enriched = accounts.map { account -> ClaudeAccount in
            var enriched = account
            let profile = readProfile(at: account.profileURL)
            enriched.email = profile.email
            enriched.organization = profile.organization
            return enriched
        }
        return Result(accounts: enriched, idsByPath: ids)
    }

    /// Combines id assignments without ever dropping one: a path that already has an id keeps it.
    public static func mergeIDs(existing: [String: String], new: [String: String]) -> [String: String] {
        existing.merging(new) { current, _ in current }
    }

    /// The folder name sanitised, with `-2`, `-3`… appended when it is empty, reserved or taken.
    static func uniqueID(forFolderName name: String, used: Set<String>) -> String {
        let base = ClaudeAccount.sanitizedID(fromFolderName: name)
        if !base.isEmpty, !used.contains(base) { return base }
        let stem = base.isEmpty ? "account" : base
        var counter = 2
        while used.contains("\(stem)-\(counter)") { counter += 1 }
        return "\(stem)-\(counter)"
    }

    struct Profile: Equatable {
        var email: String?
        var organization: String?
    }

    /// Best effort: a missing file, malformed JSON or a missing key leaves that value nil and
    /// is logged, never thrown, since an account without a label is still worth polling.
    static func readProfile(at url: URL) -> Profile {
        struct File: Decodable {
            struct OAuthAccount: Decodable {
                let emailAddress: String?
                let organizationName: String?
            }
            let oauthAccount: OAuthAccount?
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.notice("no profile file for an account, so no email or organization")
            return Profile()
        }
        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(File.self, from: data)
            if file.oauthAccount == nil {
                logger.notice("profile file has no oauthAccount, so no email or organization")
            }
            return Profile(
                email: nonEmpty(file.oauthAccount?.emailAddress),
                organization: nonEmpty(file.oauthAccount?.organizationName)
            )
        } catch {
            logger.error("couldn't read an account profile: \(error.localizedDescription, privacy: .private)")
            return Profile()
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func subfolders(of container: URL) -> [URL] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: container.path) else { return [] }
        do {
            return try fileManager
                .contentsOfDirectory(at: container, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                .filter(isUsableDirectory)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            logger.error("couldn't list the accounts folder: \(error.localizedDescription, privacy: .private)")
            return []
        }
    }

    private static func isUsableDirectory(_ url: URL) -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values.isDirectory == true
                && values.isSymbolicLink != true
                && FileManager.default.isReadableFile(atPath: url.path)
        } catch {
            return false
        }
    }

    private static func hasProfile(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: ".claude.json").path)
    }

    private static func resolvedPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
