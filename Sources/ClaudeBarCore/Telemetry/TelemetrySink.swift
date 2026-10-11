import Foundation

/// Where telemetry goes. A list rather than a single value so more destinations (an
/// OTLP/HTTP endpoint, say) can be added next to the local file without reshaping settings.
public enum TelemetrySinkConfig: Sendable, Equatable {
    case file(directory: URL)
}

public struct TelemetryConfig: Sendable, Equatable {
    public static let defaultIntervalSeconds: TimeInterval = 300
    public static let defaultRetentionDays = 90

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

/// Appends OTLP JSON requests, one per line, to daily files:
/// `metrics-YYYY-MM-DD.jsonl` and `logs-YYYY-MM-DD.jsonl`. That line-delimited layout is
/// what the OpenTelemetry Collector's `otlpjsonfile` receiver reads, and `jq` handles it too.
public struct FileTelemetrySink: TelemetrySink {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
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
        let calendar = Calendar.current
        guard let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: calendar.startOfDay(for: now)) else {
            return
        }
        for name in try fileManager.contentsOfDirectory(atPath: directory.path) {
            // Only ever touch files this sink named, so pointing the folder at a directory
            // with other content can't cost the user anything.
            guard let fileDate = Self.date(fromFileName: name), fileDate < cutoff else { continue }
            try fileManager.removeItem(at: directory.appending(path: name))
        }
    }

    static func fileName(prefix: String, on date: Date) -> String {
        "\(prefix)-\(dayFormatter().string(from: date)).jsonl"
    }

    static func date(fromFileName name: String) -> Date? {
        guard let match = name.wholeMatch(of: /(?:metrics|logs)-(\d{4}-\d{2}-\d{2})\.jsonl/) else { return nil }
        return dayFormatter().date(from: String(match.1))
    }

    // Local calendar days, so a file lines up with the day the person was actually working.
    private static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private func append(_ line: Data, to prefix: String, on date: Date) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: Self.fileName(prefix: prefix, on: date))
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            // The write error is the one worth reporting; a close failure on top adds nothing.
            try? handle.close()
            throw error
        }
        try handle.close()
    }
}
