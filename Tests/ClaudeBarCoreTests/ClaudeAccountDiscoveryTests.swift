import Foundation
import Testing
@testable import ClaudeBarCore

struct ClaudeAccountDiscoveryTests {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "claudebar-discovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @discardableResult
    private func makeAccountFolder(
        in container: URL,
        _ name: String,
        profile: String? = "{}"
    ) throws -> URL {
        let folder = container.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let profile {
            try Data(profile.utf8).write(to: folder.appending(path: ".claude.json"))
        }
        return folder
    }

    private func accountsContainer(_ home: URL) throws -> URL {
        let container = home.appending(path: ".claude-accounts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        return container
    }

    @Test func defaultIsAlwaysFirstEvenWithNothingElse() throws {
        let home = try makeHome()
        let accounts = ClaudeAccountDiscovery.discover(home: home).accounts
        #expect(accounts.map(\.id) == ["default"])
    }

    @Test func listsAccountFoldersSortedAndSkipsOnesWithoutAProfile() throws {
        let home = try makeHome()
        let container = try accountsContainer(home)
        try makeAccountFolder(in: container, "zeta")
        try makeAccountFolder(in: container, "acme")
        try makeAccountFolder(in: container, "no-profile", profile: nil)

        let accounts = ClaudeAccountDiscovery.discover(home: home).accounts

        #expect(accounts.map(\.id) == ["default", "acme", "zeta"])
        #expect(accounts.map(\.isDefault) == [true, false, false])
    }

    @Test func extraFolderThatDuplicatesADiscoveredOneIsDroppedOnce() throws {
        let home = try makeHome()
        let container = try accountsContainer(home)
        let known = try makeAccountFolder(in: container, "acme")
        let elsewhere = try makeAccountFolder(in: home.appending(path: "other", directoryHint: .isDirectory), "side")

        let accounts = ClaudeAccountDiscovery.discover(home: home, extraFolders: [known, elsewhere, elsewhere]).accounts

        #expect(accounts.map(\.id) == ["default", "acme", "side"])
    }

    @Test func symlinkedFolderIsSkipped() throws {
        let home = try makeHome()
        let container = try accountsContainer(home)
        let real = try makeAccountFolder(in: home.appending(path: "real", directoryHint: .isDirectory), "target")
        try FileManager.default.createSymbolicLink(
            at: container.appending(path: "linked"),
            withDestinationURL: real
        )

        let accounts = ClaudeAccountDiscovery.discover(home: home).accounts
        #expect(accounts.map(\.id) == ["default"])

        let viaExtra = ClaudeAccountDiscovery.discover(
            home: home,
            extraFolders: [container.appending(path: "linked", directoryHint: .isDirectory)]
        )
        #expect(viaExtra.accounts.map(\.id) == ["default"])
    }

    @Test func extraFolderNamedDefaultGetsASuffix() throws {
        let home = try makeHome()
        let folder = try makeAccountFolder(in: home.appending(path: "x", directoryHint: .isDirectory), "default")
        let accounts = ClaudeAccountDiscovery.discover(home: home, extraFolders: [folder]).accounts
        #expect(accounts.map(\.id) == ["default", "default-2"])
        #expect(accounts[1].isDefault == false)
    }

    @Test func collidingNamesGetSuffixesInDiscoveryOrder() throws {
        let home = try makeHome()
        let container = try accountsContainer(home)
        try makeAccountFolder(in: container, "Work")
        let extra = try makeAccountFolder(in: home.appending(path: "x", directoryHint: .isDirectory), "work")
        let accounts = ClaudeAccountDiscovery.discover(home: home, extraFolders: [extra]).accounts
        #expect(accounts.map(\.id) == ["default", "work", "work-2"])
    }

    @Test func readsEmailAndOrganisation() throws {
        let home = try makeHome()
        let container = try accountsContainer(home)
        try makeAccountFolder(
            in: container,
            "acme",
            profile: #"{"numStartups":3,"oauthAccount":{"emailAddress":"someone@acme.example","organizationName":"Acme Corp"}}"#
        )
        // The default account's profile sits at the home root, not inside ~/.claude.
        try Data(#"{"oauthAccount":{"emailAddress":"me@example.com"}}"#.utf8).write(to: home.appending(path: ".claude.json"))

        let accounts = ClaudeAccountDiscovery.discover(home: home).accounts

        #expect(accounts[0].email == "me@example.com")
        #expect(accounts[0].organization == nil)
        #expect(accounts[1].email == "someone@acme.example")
        #expect(accounts[1].organization == "Acme Corp")
    }

    @Test func malformedOrMissingProfileLeavesValuesNil() throws {
        let home = try makeHome()
        let container = try accountsContainer(home)
        try makeAccountFolder(in: container, "broken", profile: "{not json")
        try makeAccountFolder(in: container, "bare", profile: #"{"other":1}"#)

        let accounts = ClaudeAccountDiscovery.discover(home: home).accounts

        #expect(accounts.map(\.id) == ["default", "bare", "broken"])
        #expect(accounts.allSatisfy { $0.email == nil && $0.organization == nil })
    }

    @Test func idsStayWithTheirFolderWhenAnotherIsRemoved() throws {
        let home = try makeHome()
        let first = try makeAccountFolder(in: home.appending(path: "a", directoryHint: .isDirectory), "work")
        let second = try makeAccountFolder(in: home.appending(path: "b", directoryHint: .isDirectory), "work")

        let initial = ClaudeAccountDiscovery.discover(home: home, extraFolders: [first, second])
        #expect(initial.accounts.map(\.id) == ["default", "work", "work-2"])

        // With the first folder gone, the second keeps work-2 and does not inherit work.
        let afterRemoval = ClaudeAccountDiscovery.discover(
            home: home, extraFolders: [second], knownIDs: initial.idsByPath
        )
        #expect(afterRemoval.accounts.map(\.id) == ["default", "work-2"])

        // Re-adding the first folder gets its old id back.
        let readded = ClaudeAccountDiscovery.discover(
            home: home, extraFolders: [first, second], knownIDs: afterRemoval.idsByPath
        )
        #expect(readded.accounts.map(\.id) == ["default", "work", "work-2"])
    }

    @Test func aFreedIdIsNotReusedForANewFolder() throws {
        let home = try makeHome()
        let old = try makeAccountFolder(in: home.appending(path: "a", directoryHint: .isDirectory), "work")
        let new = try makeAccountFolder(in: home.appending(path: "b", directoryHint: .isDirectory), "work")

        let first = ClaudeAccountDiscovery.discover(home: home, extraFolders: [old])
        let second = ClaudeAccountDiscovery.discover(home: home, extraFolders: [new], knownIDs: first.idsByPath)

        #expect(first.accounts.map(\.id) == ["default", "work"])
        #expect(second.accounts.map(\.id) == ["default", "work-2"])
    }

    @Test func accountsFolderNameStillBecomesTheID() throws {
        let home = try makeHome()
        try makeAccountFolder(in: try accountsContainer(home), "acme")
        let result = ClaudeAccountDiscovery.discover(home: home)
        #expect(result.accounts.map(\.id) == ["default", "acme"])
        #expect(result.idsByPath.values.contains("acme"))
    }
}
