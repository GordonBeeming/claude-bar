import Foundation

/// Moves telemetry files out of `~/Documents/ClaudeBar Telemetry`, the old default, into the
/// current default. Documents is a TCC-protected folder, so keeping the files there made macOS
/// ask for access.
public enum TelemetryFolderMigration {
    public struct Outcome: Equatable, Sendable {
        public var failures: [String] = []
        /// True once nothing eligible is left in the old folder, so the caller can stop looking.
        public var isComplete = true
    }

    public static func legacyDirectory(home: URL) -> URL {
        home.appending(path: "Documents", directoryHint: .isDirectory)
            .appending(path: "ClaudeBar Telemetry", directoryHint: .isDirectory)
    }

    /// Only the two names the Bar Telemetry Spec defines; anything else in the folder is the
    /// person's and stays where it is.
    static func isSpecFileName(_ name: String) -> Bool {
        name.wholeMatch(of: /claudebar-(metrics|logs)-\d{4}-\d{2}-\d{2}\.jsonl/) != nil
    }

    public static func migrate(home: URL, fileManager: FileManager = .default) -> Outcome {
        var outcome = Outcome()
        let legacy = legacyDirectory(home: home)
        let destination = TelemetryConfig.defaultDirectory(home: home)

        // attributesOfItem doesn't follow links, so a symlinked root is seen as one. Documents
        // is user-writable, so a link there could point the move at, and the clean-up at, a
        // folder this app has no business in. It never becomes eligible, so don't retry it.
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: legacy.path)
        } catch {
            // Absent is the normal case for a new install. Any other failure (access denied, say)
            // means the folder couldn't be checked, so a later launch has to look again.
            if !isMissing(error) {
                outcome.failures.append("\(legacy.path): \(error.localizedDescription)")
                outcome.isComplete = false
            }
            return outcome
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            outcome.failures.append("\(legacy.path) is not a plain folder, so it was left alone")
            return outcome
        }

        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: legacy.path)
        } catch {
            outcome.failures.append("\(legacy.path): \(error.localizedDescription)")
            outcome.isComplete = false
            return outcome
        }
        for name in names.sorted() {
            do {
                let isSource = isSpecFileName(name) || name.removingSuffix(mergingSuffix).map(isSpecFileName) == true
                // A link here would be carried to the destination by the move, and the sink would
                // then write through it. It can't turn into a real file, so it is reported and
                // left, not retried.
                if isSource, !isRegularFile(legacy.appending(path: name), fileManager: fileManager) {
                    outcome.failures.append("\(name) is not a regular file, so it was left alone")
                    continue
                }
                if isSpecFileName(name) {
                    try relocate(name, from: legacy, to: destination, fileManager: fileManager)
                } else if let base = name.removingSuffix(mergingSuffix), isSpecFileName(base) {
                    // A run that stopped mid-merge. The append may or may not have landed, and
                    // a repeated line is better than a lost one, so it is merged again.
                    try merge(source: legacy.appending(path: name), base: base, from: legacy, to: destination, fileManager: fileManager)
                } else if let base = name.removingSuffix(mergedSuffix), isSpecFileName(base) {
                    // Fully appended; only the delete failed last time. Never append it again.
                    try fileManager.removeItem(at: legacy.appending(path: name))
                } else {
                    continue
                }
            } catch {
                outcome.failures.append("\(name): \(error.localizedDescription)")
                outcome.isComplete = false
            }
        }
        removeIfEmpty(legacy, fileManager: fileManager, outcome: &outcome)
        return outcome
    }

    /// The old default stored as the chosen folder: someone who clicked "Use default" under an
    /// earlier version, which wrote the then-default path. They never picked a folder, so they
    /// are treated like anyone who has not chosen one.
    public static func isLegacyDefault(_ directory: URL, home: URL) -> Bool {
        directory.standardizedFileURL.path == legacyDirectory(home: home).standardizedFileURL.path
    }

    /// Whether the old folder is worth looking at: only while the app is on the default folder
    /// (new or old), and not once a run found nothing left to do. A custom folder never moves
    /// anything.
    public static func shouldRun(selectedDirectory: URL, home: URL, alreadyMigrated: Bool) -> Bool {
        !alreadyMigrated
            && (selectedDirectory.standardizedFileURL.path == TelemetryConfig.defaultDirectory(home: home).standardizedFileURL.path
                || isLegacyDefault(selectedDirectory, home: home))
    }

    /// Returns nil when it didn't look at the old folder at all.
    public static func migrateIfNeeded(
        selectedDirectory: URL,
        home: URL,
        alreadyMigrated: Bool,
        fileManager: FileManager = .default
    ) -> Outcome? {
        guard shouldRun(selectedDirectory: selectedDirectory, home: home, alreadyMigrated: alreadyMigrated) else { return nil }
        return migrate(home: home, fileManager: fileManager)
    }

    // Neither suffix matches the spec pattern, so the sink and the pruner never touch them.
    private static let mergingSuffix = ".merging"
    private static let mergedSuffix = ".migrated"

    private static func relocate(_ name: String, from legacy: URL, to destination: URL, fileManager: FileManager) throws {
        try FileTelemetrySink.createFolderIfNeeded(destination)
        let source = legacy.appending(path: name)
        try requireRegularIfPresent(destination.appending(path: name), fileManager: fileManager)
        guard (try? fileManager.attributesOfItem(atPath: destination.appending(path: name).path)) != nil else {
            try fileManager.moveItem(at: source, to: destination.appending(path: name))
            return
        }
        let merging = legacy.appending(path: name + mergingSuffix)
        try fileManager.moveItem(at: source, to: merging)
        do {
            try merge(source: merging, base: name, from: legacy, to: destination, fileManager: fileManager)
        } catch {
            try? fileManager.moveItem(at: merging, to: source)
            throw error
        }
    }

    /// Appends the source's whole lines to the destination file, then renames it to a name that
    /// marks it as already appended before deleting it, so a failed delete can't cause a second
    /// append on the next launch.
    private static func merge(source: URL, base: String, from legacy: URL, to destination: URL, fileManager: FileManager) throws {
        try FileTelemetrySink.createFolderIfNeeded(destination)
        try requireRegularIfPresent(destination.appending(path: base), fileManager: fileManager)
        try appendWholeLines(of: source, to: destination.appending(path: base))
        let merged = legacy.appending(path: base + mergedSuffix)
        try fileManager.moveItem(at: source, to: merged)
        try fileManager.removeItem(at: merged)
    }

    private static func appendWholeLines(of source: URL, to target: URL) throws {
        let data = try Data(contentsOf: source)
        // A fragment after the last newline is a write that never finished.
        guard let end = data.lastIndex(of: 0x0A) else { return }
        let handle = try FileHandle(forUpdating: target)
        do {
            try FileTelemetrySink.dropPartialLastLine(handle)
            try handle.seekToEnd()
            try handle.write(contentsOf: data[data.startIndex...end])
        } catch {
            try? handle.close()
            throw error
        }
        try handle.close()
    }

    /// Doesn't follow links: a symlink reports as one rather than as its target.
    private static func isRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular
    }

    /// A destination that is already there must be a regular file before anything is appended
    /// to it. A missing one is fine; the caller moves the file into place instead.
    private static func requireRegularIfPresent(_ url: URL, fileManager: FileManager) throws {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw MigrationError.destinationNotRegular(url.lastPathComponent)
        }
    }

    private enum MigrationError: LocalizedError {
        case destinationNotRegular(String)

        var errorDescription: String? {
            switch self {
            case .destinationNotRegular(let name): "\(name) in the new folder is not a regular file"
            }
        }
    }

    private static func isMissing(_ error: Error) -> Bool {
        let cocoa = error as? CocoaError
        if cocoa?.code == .fileNoSuchFile || cocoa?.code == .fileReadNoSuchFile { return true }
        return (error as NSError).domain == NSPOSIXErrorDomain && (error as NSError).code == Int(ENOENT)
    }

    /// Finder litters folders with `.DS_Store`; it alone doesn't make the folder worth keeping.
    private static func removeIfEmpty(_ directory: URL, fileManager: FileManager, outcome: inout Outcome) {
        do {
            let remaining = try fileManager.contentsOfDirectory(atPath: directory.path)
            guard remaining.allSatisfy({ $0 == ".DS_Store" }) else { return }
            for name in remaining { try fileManager.removeItem(at: directory.appending(path: name)) }
            try fileManager.removeItem(at: directory)
        } catch {
            outcome.failures.append("clean-up of \(directory.path): \(error.localizedDescription)")
        }
    }
}

private extension String {
    func removingSuffix(_ suffix: String) -> String? {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : nil
    }
}
