import Foundation
import Darwin
import CryptoKit
import SwitchCore

public actor TokenScanner: TranscriptReader {
    private struct Cursor: Codable {
        var stamp: FileStamp
        var offset: UInt64 = 0
        var anchor = ""
        var firstTimestamp: Date?
        var days: [Date: ActivityDay] = [:]
        // Kept separate from activity totals: subscription calibration needs deduplication.
        var ledger: [String: TokenEvent] = [:]
        var skippedLines = 0
        var subagent = false
        var tail: Row?
        var droppingTail = false
    }
    private struct Cache: Codable {
        var version = 1
        var projects: String
        var timezone: String
        var cursors: [String: Cursor]
    }
    private struct Row: Codable {
        struct Message: Codable {
            struct Usage: Codable {
                var input_tokens: Int?
                var output_tokens: Int?
                var cache_read_input_tokens: Int?
                var cache_creation_input_tokens: Int?
                var counts: TokenCounts {
                    .init(input: max(0, input_tokens ?? 0), output: max(0, output_tokens ?? 0),
                          cacheRead: max(0, cache_read_input_tokens ?? 0), cacheWrite: max(0, cache_creation_input_tokens ?? 0))
                }
            }
            var id: String?
            var model: String?
            var usage: Usage?
            var stop_reason: String?
        }
        var type: String
        var timestamp: String?
        var isSidechain: Bool?
        var sessionId: String?
        var requestId: String?
        var accountUuid: String?
        var message: Message?
        enum CodingKeys: String, CodingKey { case type, timestamp, isSidechain, sessionId, requestId, accountUuid, message }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
            // Don't decode arbitrary tool results, attachments, or user message content.
            guard type == "user" || type == "assistant" else { return }
            timestamp = try c.decodeIfPresent(String.self, forKey: .timestamp)
            isSidechain = try c.decodeIfPresent(Bool.self, forKey: .isSidechain)
            if type == "assistant" {
                message = try c.decodeIfPresent(Message.self, forKey: .message)
                sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
                requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
                accountUuid = try c.decodeIfPresent(String.self, forKey: .accountUuid)
            }
        }
    }
    private var cursors: [String: Cursor] = [:]
    private let projects: URL
    private let cacheURL: URL?
    private let calendar: Calendar
    private let decoder = JSONDecoder()
    private let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private let whole = Date.ISO8601FormatStyle()
    private var loaded = false
    private var running = false
    private var cacheDirty = false
    private var last = UsageAnalytics()
    private let chunkSize = 1024 * 1024
    private let lineLimit = 16 * 1024 * 1024

    public init(projects: URL, cacheURL: URL? = nil, calendar: Calendar = .current) {
        self.projects = projects; self.cacheURL = cacheURL; self.calendar = calendar
    }

    public func cachedAnalytics() -> UsageAnalytics? {
        loadCache()
        guard !cursors.isEmpty else { return nil }
        var report = snapshot(); report.partial = true // verified against disk by the background scan
        return report
    }

    private func loadCache() {
        guard !loaded else { return }; loaded = true
        guard let cacheURL, let data = try? SafeFiles.read(cacheURL, limit: 128 * 1024 * 1024),
              let cache = try? decoder.decode(Cache.self, from: data), cache.version == 1,
              cache.projects == projects.path, cache.timezone == calendar.timeZone.identifier else { return }
        cursors = cache.cursors
    }

    private func saveCache() throws {
        guard let cacheURL else { return }
        try SafeFiles.privateDirectory(cacheURL.deletingLastPathComponent())
        let data = try JSONEncoder().encode(Cache(projects: projects.path, timezone: calendar.timeZone.identifier, cursors: cursors))
        try SafeFiles.atomicWrite(data, to: cacheURL)
    }

    private func snapshot() -> UsageAnalytics {
        var days: [Date: ActivityDay] = [:]
        for stored in cursors.values {
            let cursor = includingTail(stored)
            for (date, value) in cursor.days {
                var day = days[date] ?? ActivityDay(date: date); day.merge(value); days[date] = day
            }
        }
        var report = last
        report.days = days.values.sorted { $0.date < $1.date }
        report.skippedLines = cursors.values.reduce(0) { $0 + $1.skippedLines }
        report.partial = report.partial || report.skippedLines > 0
        return report
    }

    public func scan(since: Date) async throws -> TokenReport {
        _ = try await scanAnalytics()
        return ledger(since: since)
    }

    public func ledger(since: Date = .distantPast) -> TokenReport {
        var report = TokenReport.aggregate(cursors.values.flatMap { includingTail($0).ledger.values }, since: since)
        report.scannedFiles = last.scannedFiles; report.skippedFiles = last.skippedFiles
        report.partial = last.partial || cursors.values.contains { $0.skippedLines > 0 }
        return report
    }

    /// Runs to completion, yielding progressive totals. Unchanged files only require metadata and a small anchor read.
    public func scanAnalytics(progress: (@Sendable (UsageAnalytics) async -> Void)? = nil) async throws -> UsageAnalytics {
        guard !running else { throw SwitchError.busy }
        running = true; defer { running = false }
        loadCache()
        var files: [URL] = []
        var discoveryErrors = 0
        if FileManager.default.fileExists(atPath: projects.path) {
            for project in try SafeFiles.children(projects) where (try? project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                do {
                    for entry in try SafeFiles.children(project) {
                        if entry.pathExtension == "jsonl", !entry.lastPathComponent.contains(".superseded-") { files.append(entry) }
                        else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                            let subagents = entry.appendingPathComponent("subagents")
                            if FileManager.default.fileExists(atPath: subagents.path) {
                                do {
                                    files += try SafeFiles.children(subagents).filter {
                                        $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("agent-")
                                    }
                                } catch { discoveryErrors += 1 }
                            }
                        }
                    }
                } catch { discoveryErrors += 1 }
            }
        }
        let visible = Set(files.map(\.path))
        var changed = cacheDirty || !Set(cursors.keys).subtracting(visible).isEmpty
        cursors = cursors.filter { visible.contains($0.key) }
        last = UsageAnalytics(); last.totalFiles = files.count; last.skippedFiles = discoveryErrors
        last.totalBytes = files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        last.partial = true
        await progress?(snapshot())
        var lastUpdate = Date.distantPast
        var changedDuringScan = false
        for file in files.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            do {
                let fd = try SafeFiles.openRead(file)
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                let stamp = try SafeFiles.stamp(fd)
                // Match Desktop's per-file safety bound, but never silently call a skipped file complete.
                guard stamp.size <= 1024 * 1024 * 1024 else {
                    cursors.removeValue(forKey: file.path); last.skippedFiles += 1; changed = true; continue
                }
                var cursor = cursors[file.path] ?? Cursor(stamp: stamp)
                let anchorMatches = try cursor.offset <= UInt64(max(0, stamp.size)) &&
                    anchor(handle, offset: cursor.offset) == cursor.anchor
                if stamp.inode != cursor.stamp.inode || stamp.size < cursor.stamp.size ||
                    (stamp.size == cursor.stamp.size && stamp != cursor.stamp) || !anchorMatches {
                    cursor = Cursor(stamp: stamp)
                    cursors.removeValue(forKey: file.path); changed = true
                }
                if stamp == cursor.stamp && (cursor.offset == UInt64(stamp.size) || cursor.tail != nil) {
                    last.scannedFiles += 1; last.processedBytes += stamp.size; continue
                }
                changed = true
                cursor.tail = nil
                let initialOffset = cursor.offset
                try handle.seek(toOffset: initialOffset)
                var pending = Data(), consumed = initialOffset, dropping = cursor.droppingTail
                cursor.droppingTail = false
                let subagent = file.deletingLastPathComponent().lastPathComponent == "subagents"
                cursor.subagent = subagent
                while consumed < UInt64(stamp.size) {
                    try Task.checkCancellation()
                    let data = try handle.read(upToCount: min(chunkSize, Int(UInt64(stamp.size) - consumed))) ?? Data()
                    if data.isEmpty { break }
                    consumed += UInt64(data.count)
                    var start = data.startIndex
                    let newlines = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> [Int] in
                        guard let base = bytes.baseAddress else { return [] }
                        var result: [Int] = [], offset = 0
                        while offset < bytes.count, let next = memchr(base.advanced(by: offset), 10, bytes.count - offset) {
                            let index = base.distance(to: UnsafeRawPointer(next))
                            result.append(index); offset = index + 1
                        }
                        return result
                    }
                    for end in newlines {
                        if !dropping {
                            pending.append(data[start..<end])
                            if pending.count <= lineLimit { consume(pending, into: &cursor, subagent: subagent) }
                            else { cursor.skippedLines += 1 }
                        }
                        pending.removeAll(keepingCapacity: true); dropping = false
                        cursor.offset = consumed - UInt64(data.count - end - 1)
                        start = end + 1
                    }
                    if !dropping {
                        pending.append(data[start...])
                        if pending.count > lineLimit { pending.removeAll(keepingCapacity: true); dropping = true; cursor.skippedLines += 1 }
                    }
                    if Date().timeIntervalSince(lastUpdate) > 0.15 {
                        cursors[file.path] = cursor
                        var report = snapshot()
                        report.processedBytes = last.processedBytes + Int64(consumed)
                        await progress?(report); lastUpdate = Date()
                        await Task.yield()
                    }
                }
                // Desktop includes a valid final JSON row without a newline. Keep it provisional:
                // the next append replays from the last newline, replacing rather than doubling it.
                if dropping { cursor.offset = consumed; cursor.droppingTail = true }
                if !dropping, !pending.isEmpty { cursor.tail = try? decoder.decode(Row.self, from: pending) }
                cursor.stamp = stamp
                cursor.anchor = try anchor(handle, offset: cursor.offset)
                let after = try SafeFiles.stamp(fd)
                if after != stamp { changedDuringScan = true }
                cursors[file.path] = cursor
                last.scannedFiles += 1; last.processedBytes += Int64(consumed)
            } catch is CancellationError { throw CancellationError() }
            catch { cursors.removeValue(forKey: file.path); last.skippedFiles += 1; changed = true }
        }
        last.partial = changedDuringScan || last.skippedFiles > 0 || cursors.values.contains { ($0.offset < UInt64($0.stamp.size) && $0.tail == nil) || $0.skippedLines > 0 }
        // Persist removals too; file discovery may return fewer files without reading any changed file.
        if changed {
            do { try saveCache(); cacheDirty = false } catch { last.cacheWriteFailed = true; cacheDirty = true }
        }
        let result = snapshot(); await progress?(result); return result
    }

    private func anchor(_ handle: FileHandle, offset: UInt64) throws -> String {
        guard offset > 0 else { return "" }
        let length = min(offset, 4096)
        try handle.seek(toOffset: 0)
        var hash = SHA256()
        hash.update(data: try handle.read(upToCount: Int(length)) ?? Data())
        try handle.seek(toOffset: offset - length)
        hash.update(data: try handle.read(upToCount: Int(length)) ?? Data())
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func includingTail(_ stored: Cursor) -> Cursor {
        guard let tail = stored.tail else { return stored }
        var cursor = stored; consume(tail, into: &cursor, subagent: stored.subagent); return cursor
    }

    private func consume(_ data: Data, into cursor: inout Cursor, subagent: Bool) {
        guard let row = try? decoder.decode(Row.self, from: data) else { return }
        consume(row, into: &cursor, subagent: subagent)
    }

    private func consume(_ row: Row, into cursor: inout Cursor, subagent: Bool) {
        guard row.type == "user" || row.type == "assistant", subagent || row.isSidechain != true,
              let text = row.timestamp,
              let date = (try? fractional.parse(text)) ?? (try? whole.parse(text)) else { return }
        let dayDate = calendar.startOfDay(for: date)
        var day = cursor.days[dayDate] ?? ActivityDay(date: dayDate)
        if cursor.firstTimestamp == nil {
            cursor.firstTimestamp = date
            if !subagent { day.sessions += 1; day.hours[calendar.component(.hour, from: date), default: 0] += 1 }
        }
        if !subagent { day.messages += 1 }
        if row.type == "assistant", let message = row.message, let usage = message.usage, message.model != "<synthetic>" {
            let name = message.model ?? "unknown", counts = usage.counts
            var model = day.models[name] ?? ActivityModel(model: name)
            model.counts = model.counts + counts; model.messages += 1; day.models[name] = model
            if let session = row.sessionId, let id = message.id {
                let incomplete = counts.input > 0 && counts.output == 0 && counts.cacheRead == 0 && counts.cacheWrite == 0 && message.stop_reason == nil
                let event = TokenEvent(requestID: row.requestId ?? session, messageID: id, sessionID: session,
                    accountID: row.accountUuid.flatMap { UUID(uuidString: $0)?.uuidString.lowercased() },
                    timestamp: date, model: name, counts: counts, incomplete: incomplete)
                let old = cursor.ledger[event.deduplicationKey]
                if old == nil || (old!.incomplete && !event.incomplete) || (old!.incomplete == event.incomplete && event.counts.total >= old!.counts.total) {
                    cursor.ledger[event.deduplicationKey] = event
                }
            }
        }
        cursor.days[dayDate] = day
    }
}
