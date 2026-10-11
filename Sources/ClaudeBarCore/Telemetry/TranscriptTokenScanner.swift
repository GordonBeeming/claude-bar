import Foundation

/// Running token totals for one model, as counted from Claude Code transcripts.
public struct TokenTotals: Codable, Sendable, Equatable {
    public var input: Int64 = 0
    public var output: Int64 = 0
    public var cacheRead: Int64 = 0
    public var cacheWrite5m: Int64 = 0
    public var cacheWrite1h: Int64 = 0
    public var messages: Int64 = 0
    public var webSearchRequests: Int64 = 0
    public var webFetchRequests: Int64 = 0

    public init() {}

    mutating func add(_ usage: TranscriptUsage) {
        input += usage.input
        output += usage.output
        cacheRead += usage.cacheRead
        cacheWrite5m += usage.cacheWrite5m
        cacheWrite1h += usage.cacheWrite1h
        messages += 1
        webSearchRequests += usage.webSearchRequests
        webFetchRequests += usage.webFetchRequests
    }
}

/// One assistant message's usage, pulled from a transcript line.
struct TranscriptUsage: Equatable {
    var dedupeKey: String?
    var model: String
    var input: Int64
    var output: Int64
    var cacheRead: Int64
    var cacheWrite5m: Int64
    var cacheWrite1h: Int64
    var webSearchRequests: Int64
    var webFetchRequests: Int64
}

/// Where each transcript has been read up to, plus the running totals. Persisted between
/// launches so only bytes appended since the last scan are ever read.
public struct TranscriptScanState: Codable, Sendable, Equatable {
    struct Cursor: Codable, Sendable, Equatable {
        var offset: UInt64
        var modified: Date
        /// The last few dedupe keys seen in this file. Claude Code writes one line per content
        /// block, each repeating the whole message's usage, and those repeats sit next to each
        /// other, so a short window is enough to drop them.
        var recentKeys: [String]
    }

    var cursors: [String: Cursor]
    public internal(set) var totals: [String: TokenTotals]
    /// Start of the cumulative counters: OTLP's `startTimeUnixNano` for every token point.
    public let countingSince: Date
}

/// Counts tokens from Claude Code's JSONL transcripts (`~/.claude/projects/**/*.jsonl`).
/// These only cover Claude Code on this Mac; claude.ai and other machines never land here.
public struct TranscriptTokenScanner: Sendable {
    static let recentKeyLimit = 8
    private static let chunkSize = 4 * 1024 * 1024
    // Keys are only needed while a message is still being written; a file untouched for a
    // day won't get another repeat, so its window is dropped to keep the state file small.
    private static let recentKeyLifetime: TimeInterval = 86_400

    public let root: URL

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects")) {
        self.root = root
    }

    /// Starts counting from now: every existing transcript is marked as read to its current
    /// end, so turning telemetry on doesn't backfill a history that can run to gigabytes.
    public func baseline(now: Date) throws -> TranscriptScanState {
        var cursors: [String: TranscriptScanState.Cursor] = [:]
        for file in try transcriptFiles() {
            cursors[file.key] = .init(offset: file.size, modified: file.modified, recentKeys: [])
        }
        return TranscriptScanState(cursors: cursors, totals: [:], countingSince: now)
    }

    /// Reads whatever was appended since the last scan and adds it to the totals. A file that
    /// first appears after the baseline is read from the start; one that shrank (rewritten)
    /// is re-baselined at its new end.
    ///
    /// A file that can't be read (deleted between listing and opening, permissions) is
    /// skipped and reported back rather than failing the whole scan; its cursor is left
    /// where it was so the next scan retries it.
    @discardableResult
    public func scan(_ state: inout TranscriptScanState, now: Date) throws -> [ScanFailure] {
        var seen = Set<String>()
        var failures: [ScanFailure] = []
        for file in try transcriptFiles() {
            seen.insert(file.key)
            var cursor = state.cursors[file.key] ?? .init(offset: 0, modified: file.modified, recentKeys: [])
            if file.size < cursor.offset {
                // A rewrite (compaction, truncation) can keep messages already counted, and
                // the dedupe window is far too small to recognise them, so replaying it would
                // double-count. Re-baseline instead: only what's appended from here counts.
                cursor = .init(offset: file.size, modified: file.modified, recentKeys: [])
            }
            if file.size > cursor.offset {
                // Totals are staged per file so a read that fails part-way can't leave half a
                // file counted while its cursor says none of it was.
                var staged = cursor
                var stagedTotals = state.totals
                do {
                    try read(file.url, upTo: file.size, cursor: &staged, totals: &stagedTotals)
                    cursor = staged
                    state.totals = stagedTotals
                } catch {
                    failures.append(ScanFailure(file: file.key, message: error.localizedDescription))
                    if let existing = state.cursors[file.key] { cursor = existing }
                    else { continue }
                }
            }
            cursor.modified = file.modified
            if now.timeIntervalSince(file.modified) > Self.recentKeyLifetime {
                cursor.recentKeys = []
            }
            state.cursors[file.key] = cursor
        }
        // Deleted transcripts can't grow again; forgetting them keeps the state bounded.
        state.cursors = state.cursors.filter { seen.contains($0.key) }
        return failures
    }

    public struct ScanFailure: Sendable, Equatable {
        public let file: String
        public let message: String
    }

    private struct TranscriptFile {
        let url: URL
        let key: String
        let size: UInt64
        let modified: Date
    }

    private func transcriptFiles() throws -> [TranscriptFile] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return []
        }
        let rootPath = root.standardizedFileURL.path
        var files: [TranscriptFile] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            // A transcript removed while the directory is being walked has no values to read;
            // it simply isn't part of this scan.
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize
            else { continue }
            let path = url.standardizedFileURL.path
            let key = path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
            files.append(TranscriptFile(
                url: url,
                key: key,
                size: UInt64(size),
                modified: values.contentModificationDate ?? .distantPast
            ))
        }
        return files
    }

    private func read(
        _ url: URL,
        upTo size: UInt64,
        cursor: inout TranscriptScanState.Cursor,
        totals: inout [String: TokenTotals]
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        // A read-only handle has nothing to flush, so a failed close can't lose data.
        defer { try? handle.close() }
        try handle.seek(toOffset: cursor.offset)

        var pending = Data()
        var position = cursor.offset
        while position < size {
            let want = Int(min(UInt64(Self.chunkSize), size - position))
            guard let chunk = try handle.read(upToCount: want), !chunk.isEmpty else { break }
            position += UInt64(chunk.count)
            pending.append(chunk)

            // Only complete lines are consumed; a trailing partial line is still being
            // written and is picked up whole on a later scan.
            guard let lastNewline = pending.lastIndex(of: 0x0A) else { continue }
            let complete = pending[pending.startIndex...lastNewline]
            for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
                consume(Data(line), cursor: &cursor, totals: &totals)
            }
            cursor.offset += UInt64(complete.count)
            pending = Data(pending[pending.index(after: lastNewline)...])
        }
    }

    private func consume(_ line: Data, cursor: inout TranscriptScanState.Cursor, totals: inout [String: TokenTotals]) {
        guard let usage = Self.parse(line: line) else { return }
        if let key = usage.dedupeKey {
            guard !cursor.recentKeys.contains(key) else { return }
            cursor.recentKeys.append(key)
            if cursor.recentKeys.count > Self.recentKeyLimit {
                cursor.recentKeys.removeFirst(cursor.recentKeys.count - Self.recentKeyLimit)
            }
        }
        totals[usage.model, default: TokenTotals()].add(usage)
    }

    private static let usageMarker = Data("\"output_tokens\"".utf8)

    static func parse(line: Data) -> TranscriptUsage? {
        // Most lines (user turns, tool results, metadata) carry no usage; skipping them
        // before JSON decoding keeps a large catch-up scan cheap.
        guard line.range(of: usageMarker) != nil else { return nil }
        guard let entry = try? JSONDecoder().decode(Line.self, from: line),
              let message = entry.message,
              let usage = message.usage,
              let model = message.model,
              // Claude Code's locally generated stand-in messages (errors, interruptions)
              // never reached the API.
              model != "<synthetic>"
        else {
            return nil
        }

        let dedupeKey: String? = switch (message.id, entry.requestId) {
        case (nil, nil): nil
        case let (id, request): "\(id ?? "")|\(request ?? "")"
        }

        let cacheWrite = usage.cacheCreationInputTokens ?? 0
        let write1h = usage.cacheCreation?.ephemeral1h ?? 0
        // Without the TTL breakdown the write is counted at the default 5-minute TTL.
        let write5m = usage.cacheCreation?.ephemeral5m ?? max(cacheWrite - write1h, 0)

        return TranscriptUsage(
            dedupeKey: dedupeKey,
            model: model,
            input: usage.inputTokens ?? 0,
            output: usage.outputTokens ?? 0,
            cacheRead: usage.cacheReadInputTokens ?? 0,
            cacheWrite5m: write5m,
            cacheWrite1h: write1h,
            webSearchRequests: usage.serverToolUse?.webSearchRequests ?? 0,
            webFetchRequests: usage.serverToolUse?.webFetchRequests ?? 0
        )
    }

    private struct Line: Decodable {
        let requestId: String?
        let message: Message?
    }

    private struct Message: Decodable {
        let id: String?
        let model: String?
        let usage: Usage?
    }

    private struct Usage: Decodable {
        let inputTokens: Int64?
        let outputTokens: Int64?
        let cacheCreationInputTokens: Int64?
        let cacheReadInputTokens: Int64?
        let cacheCreation: CacheCreation?
        let serverToolUse: ServerToolUse?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreation = "cache_creation"
            case serverToolUse = "server_tool_use"
        }
    }

    private struct CacheCreation: Decodable {
        let ephemeral5m: Int64?
        let ephemeral1h: Int64?

        enum CodingKeys: String, CodingKey {
            case ephemeral5m = "ephemeral_5m_input_tokens"
            case ephemeral1h = "ephemeral_1h_input_tokens"
        }
    }

    private struct ServerToolUse: Decodable {
        let webSearchRequests: Int64?
        let webFetchRequests: Int64?

        enum CodingKeys: String, CodingKey {
            case webSearchRequests = "web_search_requests"
            case webFetchRequests = "web_fetch_requests"
        }
    }
}
