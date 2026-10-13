import Foundation
import Testing
@testable import ClaudeBarCore

private func temporaryHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "claudebar-home-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct Layout {
    let home: URL
    var old: URL { home.appending(path: "Documents/ClaudeBar Telemetry", directoryHint: .isDirectory) }
    var new: URL { TelemetryConfig.defaultDirectory(home: home) }

    init(createOld: Bool = true) throws {
        home = try temporaryHome()
        if createOld { try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true) }
    }

    func write(_ name: String, _ text: String, in directory: URL? = nil) throws {
        let folder = directory ?? old
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: folder.appending(path: name))
    }

    func read(_ name: String, in directory: URL? = nil) throws -> String {
        String(decoding: try Data(contentsOf: (directory ?? new).appending(path: name)), as: UTF8.self)
    }

    func names(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }
}

struct TelemetryFolderCleanupTests {
    @Test func removesTheOldFolderOnceEmptyEvenWithADSStore() throws {
        let layout = try Layout()
        try layout.write("claudebar-metrics-2026-10-01.jsonl", "m\n")
        try layout.write(".DS_Store", "finder")

        let outcome = TelemetryFolderMigration.migrate(home: layout.home)

        #expect(outcome.isComplete)
        #expect(!FileManager.default.fileExists(atPath: layout.old.path))
    }

    @Test func keepsTheOldFolderAndItsDSStoreWhenSomethingElseIsInIt() throws {
        let layout = try Layout()
        try layout.write("claudebar-metrics-2026-10-01.jsonl", "m\n")
        try layout.write("notes.txt", "mine")
        try layout.write(".DS_Store", "finder")

        _ = TelemetryFolderMigration.migrate(home: layout.home)

        #expect(layout.names(in: layout.old) == [".DS_Store", "notes.txt"])
    }

    @Test func doesNothingWhenThereIsNoOldFolder() throws {
        let layout = try Layout(createOld: false)

        let outcome = TelemetryFolderMigration.migrate(home: layout.home)

        #expect(outcome == .init())
        #expect(!FileManager.default.fileExists(atPath: layout.new.path))
    }

    @Test func rejectsAnOldFolderThatIsASymbolicLinkWithoutTouchingItsTarget() throws {
        let layout = try Layout(createOld: false)
        let target = layout.home.appending(path: "elsewhere", directoryHint: .isDirectory)
        try layout.write("claudebar-metrics-2026-10-01.jsonl", "m\n", in: target)
        try FileManager.default.createDirectory(at: layout.old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: layout.old, withDestinationURL: target)

        let outcome = TelemetryFolderMigration.migrate(home: layout.home)

        #expect(outcome.failures.count == 1)
        #expect(outcome.isComplete)
        #expect(layout.names(in: target) == ["claudebar-metrics-2026-10-01.jsonl"])
        #expect(layout.names(in: layout.new).isEmpty)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: layout.old.path)) != nil)
    }
}

/// Fails the first removal of a file the merge has finished with, the way a permissions or
/// sync hiccup would, then behaves normally.
private final class FlakyRemovalFileManager: FileManager, @unchecked Sendable {
    var failuresLeft = 1

    override func removeItem(at url: URL) throws {
        if failuresLeft > 0, url.lastPathComponent.hasSuffix(".migrated") {
            failuresLeft -= 1
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
    }
}

struct TelemetryFolderMergeTests {
    @Test func appendsOnlyWholeLinesWhenTheSameNameAlreadyExistsAtTheDestination() throws {
        let layout = try Layout()
        try layout.write("claudebar-metrics-2026-10-01.jsonl", "a\n", in: layout.new)
        try layout.write("claudebar-metrics-2026-10-01.jsonl", "b\nc\npartial")

        let outcome = TelemetryFolderMigration.migrate(home: layout.home)

        #expect(outcome.failures.isEmpty)
        #expect(try layout.read("claudebar-metrics-2026-10-01.jsonl") == "a\nb\nc\n")
        #expect(!FileManager.default.fileExists(atPath: layout.old.path))
    }

    @Test func cutsAPartialLastLineOffTheDestinationBeforeAppending() throws {
        let layout = try Layout()
        try layout.write("claudebar-logs-2026-10-01.jsonl", "a\nhalf", in: layout.new)
        try layout.write("claudebar-logs-2026-10-01.jsonl", "b\n")

        _ = TelemetryFolderMigration.migrate(home: layout.home)

        #expect(try layout.read("claudebar-logs-2026-10-01.jsonl") == "a\nb\n")
    }

    @Test func aRetryAfterAFailedRemovalDoesNotAppendTwice() throws {
        let layout = try Layout()
        try layout.write("claudebar-metrics-2026-10-01.jsonl", "a\n", in: layout.new)
        try layout.write("claudebar-metrics-2026-10-01.jsonl", "b\n")

        let first = TelemetryFolderMigration.migrate(home: layout.home, fileManager: FlakyRemovalFileManager())
        #expect(first.failures.count >= 1)
        #expect(!first.isComplete)
        #expect(try layout.read("claudebar-metrics-2026-10-01.jsonl") == "a\nb\n")

        let second = TelemetryFolderMigration.migrate(home: layout.home)
        #expect(second.failures.isEmpty)
        #expect(second.isComplete)
        #expect(try layout.read("claudebar-metrics-2026-10-01.jsonl") == "a\nb\n")
        #expect(!FileManager.default.fileExists(atPath: layout.old.path))
    }

    @Test func aMergeInterruptedBeforeItFinishedIsPickedUpAgain() throws {
        let layout = try Layout()
        try layout.write("claudebar-metrics-2026-10-01.jsonl", "a\n", in: layout.new)
        try layout.write("claudebar-metrics-2026-10-01.jsonl.merging", "b\n")

        let outcome = TelemetryFolderMigration.migrate(home: layout.home)

        #expect(outcome.isComplete)
        #expect(try layout.read("claudebar-metrics-2026-10-01.jsonl") == "a\nb\n")
        #expect(!FileManager.default.fileExists(atPath: layout.old.path))
    }

    @Test func aFileThatCannotMoveIsReportedAndKeepsTheMigrationOpenForARetry() throws {
        let layout = try Layout()
        try layout.write("claudebar-logs-2026-10-01.jsonl", "l\n")
        // A directory squatting on the destination name makes both the move and the merge fail.
        try FileManager.default.createDirectory(
            at: layout.new.appending(path: "claudebar-logs-2026-10-01.jsonl"),
            withIntermediateDirectories: true
        )

        let outcome = TelemetryFolderMigration.migrate(home: layout.home)

        #expect(outcome.failures.count == 1)
        #expect(!outcome.isComplete)
        #expect(try layout.read("claudebar-logs-2026-10-01.jsonl", in: layout.old) == "l\n")
    }
}

struct TelemetryFolderMigrationGateTests {
    @Test func runsOnlyForTheDefaultFolderUntilItIsMarkedMigrated() throws {
        let home = try temporaryHome()
        let fresh = TelemetryConfig.defaultDirectory(home: home)
        let custom = home.appending(path: "Elsewhere", directoryHint: .isDirectory)

        #expect(TelemetryFolderMigration.shouldRun(selectedDirectory: fresh, home: home, alreadyMigrated: false))
        #expect(!TelemetryFolderMigration.shouldRun(selectedDirectory: fresh, home: home, alreadyMigrated: true))
        #expect(!TelemetryFolderMigration.shouldRun(selectedDirectory: custom, home: home, alreadyMigrated: false))
    }

    @Test func theStoredOldDefaultCountsAsNoFolderChosen() throws {
        let layout = try Layout()
        let unstandardized = layout.home.appending(path: "Documents/./ClaudeBar Telemetry/", directoryHint: .isDirectory)
        let custom = layout.home.appending(path: "Documents/Other", directoryHint: .isDirectory)

        #expect(TelemetryFolderMigration.isLegacyDefault(layout.old, home: layout.home))
        #expect(TelemetryFolderMigration.isLegacyDefault(unstandardized, home: layout.home))
        #expect(!TelemetryFolderMigration.isLegacyDefault(custom, home: layout.home))
        #expect(!TelemetryFolderMigration.isLegacyDefault(layout.new, home: layout.home))
        #expect(TelemetryFolderMigration.shouldRun(selectedDirectory: unstandardized, home: layout.home, alreadyMigrated: false))
        #expect(!TelemetryFolderMigration.shouldRun(selectedDirectory: unstandardized, home: layout.home, alreadyMigrated: true))
        #expect(!TelemetryFolderMigration.shouldRun(selectedDirectory: custom, home: layout.home, alreadyMigrated: false))
    }

    @Test func movesFilesWhenTheStoredFolderIsTheOldDefault() throws {
        let layout = try Layout()
        try layout.write("claudebar-logs-2026-10-01.jsonl", "l\n")

        let outcome = TelemetryFolderMigration.migrateIfNeeded(
            selectedDirectory: layout.old, home: layout.home, alreadyMigrated: false
        )

        #expect(outcome?.isComplete == true)
        #expect(layout.names(in: layout.new) == ["claudebar-logs-2026-10-01.jsonl"])
    }

    @Test func aCustomFolderMeansNothingIsMoved() throws {
        let layout = try Layout()
        try layout.write("claudebar-logs-2026-10-01.jsonl", "l\n")
        let custom = layout.home.appending(path: "Elsewhere", directoryHint: .isDirectory)

        let ran = TelemetryFolderMigration.migrateIfNeeded(
            selectedDirectory: custom, home: layout.home, alreadyMigrated: false
        )

        #expect(ran == nil)
        #expect(layout.names(in: layout.old) == ["claudebar-logs-2026-10-01.jsonl"])
    }
}

struct TelemetryDefaultDirectoryTests {
    @Test func defaultsToApplicationSupportUnderTheGivenHome() throws {
        let home = try temporaryHome()
        #expect(TelemetryConfig.defaultDirectory(home: home).path
            == home.appending(path: "Library/Application Support/ClaudeBar/Telemetry").path)
    }
}

struct TelemetryFolderMigrationTests {
    @Test func movesSpecNamedFilesIntoTheNewDefaultAndLeavesEverythingElse() throws {
        let layout = try Layout()
        try layout.write("claudebar-metrics-2026-10-01.jsonl", "m\n")
        try layout.write("claudebar-logs-2026-10-01.jsonl", "l\n")
        try layout.write("notes.txt", "mine")
        try layout.write("claudebar-metrics-2026-1-1.jsonl", "bad date\n")
        try layout.write("codexbar-metrics-2026-10-01.jsonl", "other service\n")

        let outcome = TelemetryFolderMigration.migrate(home: layout.home)

        #expect(outcome.failures.isEmpty)
        #expect(outcome.isComplete)
        #expect(layout.names(in: layout.new) == ["claudebar-logs-2026-10-01.jsonl", "claudebar-metrics-2026-10-01.jsonl"])
        #expect(try layout.read("claudebar-metrics-2026-10-01.jsonl") == "m\n")
        #expect(layout.names(in: layout.old) == ["claudebar-metrics-2026-1-1.jsonl", "codexbar-metrics-2026-10-01.jsonl", "notes.txt"])
    }

    @Test func createsTheNewFolderOwnerOnly() throws {
        let layout = try Layout()
        try layout.write("claudebar-logs-2026-10-01.jsonl", "l\n")

        _ = TelemetryFolderMigration.migrate(home: layout.home)

        let attributes = try FileManager.default.attributesOfItem(atPath: layout.new.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }
}
