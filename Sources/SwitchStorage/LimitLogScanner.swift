import Foundation
import SwitchCore

/// Claude Code records `quotaLimits` (with the server's `resetsAt`) on the reply that hit a limit.
/// Transcripts carry no account UUID, so hits are keyed by session for the caller to attribute.
struct LimitLogScanner {
    private var cursors: [String: (inode: UInt64, offset: UInt64)] = [:]
    private var hits: [String: ResetHint] = [:]
    private var sessions: [String: String] = [:]
    private static let marker = Data(#""quotaLimits""#.utf8)

    /// Session ID → hints still in the future.
    mutating func scan(projects: URL, now: Date = Date()) -> [String: [ResetHint]] {
        // Bounded per call; a large backlog is worked through over later refreshes, newest files first.
        var budget = 16 * 1024 * 1024
        let recent = now.addingTimeInterval(-8 * 86400)
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        var dated: [(url: URL, modified: Date)] = []
        for project in (try? SafeFiles.children(projects)) ?? [] {
            for file in (try? SafeFiles.children(project)) ?? [] where file.pathExtension == "jsonl" {
                let date = modified(file)
                if date > recent { dated.append((file, date)) }
            }
        }
        let files: [URL] = dated.sorted { $0.modified > $1.modified }.map { $0.url }
        let visible = Set(files.map { $0.path })
        cursors = cursors.filter { visible.contains($0.key) }
        for file in files {
            guard budget > 0 else { break }
            guard let fd = try? SafeFiles.openRead(file) else { continue }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            guard let stamp = try? SafeFiles.stamp(fd) else { continue }
            var cursor = cursors[file.path] ?? (stamp.inode, 0)
            if cursor.inode != stamp.inode || UInt64(stamp.size) < cursor.offset { cursor = (stamp.inode, 0) }
            guard UInt64(stamp.size) > cursor.offset, (try? handle.seek(toOffset: cursor.offset)) != nil,
                  let data = try? handle.read(upToCount: min(budget, 8 * 1024 * 1024)),
                  let newline = data.lastIndex(of: 10) else { continue }
            budget -= data.count
            let complete = data[...newline]
            if complete.range(of: Self.marker) != nil {
                for line in complete.split(separator: 10) where line.range(of: Self.marker) != nil { record(Data(line)) }
            }
            cursor.offset += UInt64(complete.count)
            cursors[file.path] = cursor
        }
        hits = hits.filter { $0.value.resetsAt > now }
        var result: [String: [ResetHint]] = [:]
        for (key, hint) in hits { if let session = sessions[key] { result[session, default: []].append(hint) } }
        return result
    }

    private mutating func record(_ line: Data) {
        guard line.count <= 2 * 1024 * 1024, let row = try? JSONDecoder().decode(JSONValue.self, from: line),
              let session = row["sessionId"].string, let seen = Dates.parse(row["timestamp"]) else { return }
        let quota = row["quotaLimits"]
        guard ["rejected", "allowed_warning"].contains(quota["status"].string ?? ""),
              let window = quota["rateLimitType"].string, ResetInference.lengths[window] != nil,
              let resets = Dates.parse(quota["resetsAt"]) else { return }
        let key = session + "/" + window
        if let old = hits[key], old.seenAt >= seen { return }
        hits[key] = ResetHint(windowID: window, resetsAt: resets, seenAt: seen); sessions[key] = session
    }
}
