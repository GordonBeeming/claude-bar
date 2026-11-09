import Foundation
import Testing
@testable import ClaudeBarCore

struct ClaudeAccountTests {
    private let home = URL(filePath: "/Users/x", directoryHint: .isDirectory)

    private func account(_ folder: String, id: String = "asfaudits") -> ClaudeAccount {
        ClaudeAccount(
            id: id,
            configDir: home.appending(path: ".claude-accounts/\(folder)", directoryHint: .isDirectory),
            isDefault: false,
            profileURL: home.appending(path: ".claude-accounts/\(folder)/.claude.json")
        )
    }

    @Test func defaultAccountPaths() {
        let account = ClaudeAccount.standard(home: home)
        #expect(account.id == "default")
        #expect(account.isDefault)
        #expect(account.keychainService == "Claude Code-credentials")
        #expect(account.selfContainedService == "com.gordonbeeming.ClaudeBar.oauth")
        #expect(account.credentialsFileURL.path == "/Users/x/.claude/.credentials.json")
        #expect(account.transcriptsRoot.path == "/Users/x/.claude/projects")
        #expect(account.profileURL.path == "/Users/x/.claude.json")
        #expect(account.telemetryFileServiceName == "claudebar")
        #expect(account.telemetryStateFileName == "telemetry-state.json")
    }

    @Test func otherAccountPaths() {
        let account = account("asfaudits")
        #expect(account.credentialsFileURL.path == "/Users/x/.claude-accounts/asfaudits/.credentials.json")
        #expect(account.transcriptsRoot.path == "/Users/x/.claude-accounts/asfaudits/projects")
        #expect(account.profileURL.path == "/Users/x/.claude-accounts/asfaudits/.claude.json")
        #expect(account.selfContainedService == "com.gordonbeeming.ClaudeBar.oauth.asfaudits")
        #expect(account.telemetryFileServiceName == "claudebar.asfaudits")
        #expect(account.telemetryStateFileName == "telemetry-state.asfaudits.json")
    }

    @Test func keychainSuffixIsFirstEightHexOfSHA256OfThePath() {
        // printf '%s' /Users/x/.claude-accounts/asfaudits | shasum -a 256
        #expect(account("asfaudits").keychainService == "Claude Code-credentials-c0f0f4e0")
        let real = ClaudeAccount(
            id: "asfaudits",
            configDir: URL(filePath: "/Users/gordonbeeming/.claude-accounts/asfaudits", directoryHint: .isDirectory),
            isDefault: false,
            profileURL: URL(filePath: "/unused")
        )
        // The value Claude Code itself uses for this folder.
        #expect(real.keychainService == "Claude Code-credentials-dcc401ce")
    }

    @Test func keychainHashIgnoresATrailingSlash() {
        let slashed = ClaudeAccount(
            id: "a",
            configDir: URL(filePath: "/Users/x/.claude-accounts/asfaudits/", directoryHint: .isDirectory),
            isDefault: false,
            profileURL: URL(filePath: "/unused")
        )
        #expect(slashed.keychainService == account("asfaudits").keychainService)
    }

    @Test(arguments: [
        ("asfaudits", "asfaudits"),
        ("ASF Audits", "asf-audits"),
        ("work__client.2", "work-client-2"),
        ("--edge--", "edge"),
        ("a   b", "a-b"),
        ("日本語", ""),
        ("", ""),
    ])
    func sanitisesFolderNames(name: String, expected: String) {
        #expect(ClaudeAccount.sanitizedID(fromFolderName: name) == expected)
    }

    @Test func idsAreUniqueAndDefaultIsReserved() {
        #expect(ClaudeAccountDiscovery.uniqueID(forFolderName: "default", used: ["default"]) == "default-2")
        #expect(ClaudeAccountDiscovery.uniqueID(forFolderName: "Work", used: ["default", "work"]) == "work-2")
        #expect(ClaudeAccountDiscovery.uniqueID(forFolderName: "Work", used: ["default", "work", "work-2"]) == "work-3")
        #expect(ClaudeAccountDiscovery.uniqueID(forFolderName: "日本語", used: ["default"]) == "account-2")
    }

    @Test func displayNamePrefersEmail() {
        var named = account("asfaudits")
        #expect(named.displayName == "asfaudits")
        named.email = "a@b.com"
        #expect(named.displayName == "a@b.com")
    }

    @Test func telemetryResourceCarriesAccountAttributes() throws {
        var named = account("asfaudits")
        func attributes(_ account: ClaudeAccount) -> [String: OTLP.AnyValue] {
            Dictionary(
                uniqueKeysWithValues: account.telemetryResource(version: "9", hostName: "h").attributes.map { ($0.key, $0.value) }
            )
        }

        var values = attributes(named)
        #expect(values["service.name"] == .string("claudebar"))
        #expect(values["bar.spec.version"] == .string("1"))
        #expect(values["account.id"] == .string("asfaudits"))
        #expect(values["account.name"] == nil)

        named.email = "gbeeming@asfaudits.com.au"
        values = attributes(named)
        #expect(values["account.name"] == .string("gbeeming@asfaudits.com.au"))

        let standard = attributes(ClaudeAccount.standard(home: home))
        #expect(standard["account.id"] == .string("default"))
        #expect(standard["service.name"] == .string("claudebar"))
    }

    @Test func selfContainedIdentityReplacesTheProfileLabel() {
        var profiled = account("asfaudits")
        profiled.email = "profile@example.com"
        profiled.organization = "Profile Org"

        let signedInAs = profiled.withIdentity(email: "other@example.com", organization: "Other Org")
        #expect(signedInAs.email == "other@example.com")
        #expect(signedInAs.organization == "Other Org")

        // No recorded identity means no label rather than the profile's possibly wrong one.
        let unknown = profiled.withIdentity(email: nil, organization: nil)
        #expect(unknown.email == nil)
        #expect(unknown.displayName == "asfaudits")
        #expect(!unknown.telemetryResource(version: "1", hostName: "h").attributes.contains { $0.key == "account.name" })
    }
}
