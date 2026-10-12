import Foundation

/// Where telemetry goes. A list rather than a single value so more destinations (an
/// OTLP/HTTP endpoint, say) can be added next to the local file without reshaping settings.
public enum TelemetrySinkConfig: Sendable, Equatable {
    case file(directory: URL)
}

public struct TelemetryConfig: Sendable, Equatable {
    public static let defaultIntervalSeconds: TimeInterval = 300
    public static let defaultRetentionDays = 90
    /// The ranges the Bar Telemetry Spec lets another app ask for, so settings and the URL
    /// scheme agree on what's valid.
    public static let intervalMinutesRange = 1...1440
    /// 0 is "keep forever".
    public static let retentionDaysRange = 0...3650

    /// Somewhere a person can find without knowing macOS's hidden app folders.
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Documents", directoryHint: .isDirectory)
            .appending(path: "ClaudeBar Telemetry", directoryHint: .isDirectory)
    }

    public var enabled: Bool
    public var intervalSeconds: TimeInterval
    /// Days of files to keep; nil keeps everything.
    public var retentionDays: Int?
    public var sinks: [TelemetrySinkConfig]

    public init(
        enabled: Bool = false,
        intervalSeconds: TimeInterval = Self.defaultIntervalSeconds,
        retentionDays: Int? = Self.defaultRetentionDays,
        sinks: [TelemetrySinkConfig] = [.file(directory: Self.defaultDirectory)]
    ) {
        self.enabled = enabled
        // A floor keeps a hand-edited 0 from turning the loop into a busy spin.
        self.intervalSeconds = max(intervalSeconds, 60)
        self.retentionDays = retentionDays.map { max($0, 1) }
        self.sinks = sinks
    }
}

public protocol TelemetrySink: Sendable {
    func export(metrics: OTLP.MetricsRequest, at date: Date) throws
    func export(logs: OTLP.LogsRequest, at date: Date) throws
    /// Drops whatever this sink keeps that is older than `retentionDays` before `now`.
    func prune(retentionDays: Int, now: Date) throws
}

public func makeSinks(_ configs: [TelemetrySinkConfig]) -> [any TelemetrySink] {
    configs.map { config in
        switch config {
        case .file(let directory): FileTelemetrySink(directory: directory)
        }
    }
}

/// Appends OTLP JSON requests, one per line, to daily files named
/// `<service>-metrics-YYYY-MM-DD.jsonl` and `<service>-logs-YYYY-MM-DD.jsonl`, the layout the
/// Bar Telemetry Spec defines. It's also what the OpenTelemetry Collector's `otlpjsonfile`
/// receiver reads, and `jq` handles it too.
public struct FileTelemetrySink: TelemetrySink {
    public static let defaultServiceName = "claudebar"

    public let directory: URL
    public let serviceName: String

    public init(directory: URL, serviceName: String = Self.defaultServiceName) {
        self.directory = directory
        self.serviceName = serviceName
    }

    public func export(metrics: OTLP.MetricsRequest, at date: Date) throws {
        try append(OTLP.encodeLine(metrics), to: "metrics", on: date)
    }

    public func export(logs: OTLP.LogsRequest, at date: Date) throws {
        guard !logs.logRecords.isEmpty else { return }
        try append(OTLP.encodeLine(logs), to: "logs", on: date)
    }

    public func prune(retentionDays: Int, now: Date) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let calendar = Self.utcCalendar
        guard let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: calendar.startOfDay(for: now)) else {
            return
        }
        for name in try fileManager.contentsOfDirectory(atPath: directory.path) {
            // Only ever touch files named to this sink's pattern, so pointing the folder at a
            // directory with other content, or files an older version named differently, can't
            // cost the user anything.
            guard let fileDate = date(fromFileName: name), fileDate < cutoff else { continue }
            try fileManager.removeItem(at: directory.appending(path: name))
        }
    }

    func fileName(kind: String, on date: Date) -> String {
        "\(serviceName)-\(kind)-\(Self.dayFormatter().string(from: date)).jsonl"
    }

    func date(fromFileName name: String) -> Date? {
        let suffix = ".jsonl"
        for kind in ["metrics", "logs"] {
            let prefix = "\(serviceName)-\(kind)-"
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { continue }
            let day = name.dropFirst(prefix.count).dropLast(suffix.count)
            guard day.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil else { return nil }
            return Self.dayFormatter().date(from: String(day))
        }
        return nil
    }

    // UTC days, so a reader in any time zone agrees on which file a moment landed in.
    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    private static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = utcCalendar
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    /// Creates the telemetry folder readable only by its owner, if it doesn't exist yet. Every
    /// place that might create it goes through here, so it's private whichever gets there first.
    /// Permissions are only set on a folder created here; a folder the person picked (Documents
    /// itself, say) keeps whatever permissions they gave it.
    public static func createFolderIfNeeded(_ directory: URL) throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func append(_ line: Data, to kind: String, on date: Date) throws {
        let fileManager = FileManager.default
        try Self.createFolderIfNeeded(directory)
        let url = directory.appending(path: fileName(kind: kind, on: date))
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        let handle = try FileHandle(forUpdating: url)
        do {
            try Self.dropPartialLastLine(handle)
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            // The write error is the one worth reporting; a close failure on top adds nothing.
            try? handle.close()
            throw error
        }
        try handle.close()
    }

    /// A crash mid-write can leave a line without its `\n`. Appending after it would glue the
    /// next record onto the fragment and spoil both, so the fragment is cut off first.
    static func dropPartialLastLine(_ handle: FileHandle) throws {
        let size = try handle.seekToEnd()
        guard size > 0 else { return }
        try handle.seek(toOffset: size - 1)
        guard let last = try handle.read(upToCount: 1), last.first != 0x0A else { return }

        let chunk: UInt64 = 64 * 1024
        var end = size
        while end > 0 {
            let start = end > chunk ? end - chunk : 0
            try handle.seek(toOffset: start)
            guard let data = try handle.read(upToCount: Int(end - start)), !data.isEmpty else { break }
            if let newline = data.lastIndex(of: 0x0A) {
                try handle.truncate(atOffset: start + UInt64(data.distance(from: data.startIndex, to: newline)) + 1)
                return
            }
            end = start
        }
        try handle.truncate(atOffset: 0)
    }
}
