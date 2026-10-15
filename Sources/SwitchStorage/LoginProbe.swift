import Foundation
import SQLite3
import SwitchCore

/// Local cookie evidence only. Absence is not proof of server-side revocation.
public enum LoginProbe {
    struct Observation: Sendable {
        var signedIn: Bool
        var validUntil: Date?
    }

    /// For frequent status polling only. Callers own the cache and invalidate it across login/process changes.
    public struct Cache: Sendable {
        private struct Entry: Sendable {
            var url: URL
            var signature: [FileStamp?]
            var observedAt: Date
            var observation: Observation
        }
        private var entry: Entry?
        private let probe: @Sendable (URL, Date) -> Observation?
        public init() { probe = { LoginProbe.observation(cookies: $0, now: $1) } }
        init(probe: @escaping @Sendable (URL, Date) -> Observation?) { self.probe = probe }

        public mutating func invalidate() { entry = nil }

        public mutating func signedIn(cookies url: URL, now: Date = Date()) -> Bool? {
            do {
                let signature = try LoginProbe.cookieFiles(url).map(LoginProbe.stamp)
                if let entry, entry.url == url, entry.signature == signature,
                   now >= entry.observedAt, now.timeIntervalSince(entry.observedAt) < 60,
                   entry.observation.validUntil.map({ now < $0 }) ?? true {
                    return entry.observation.signedIn
                }
                entry = nil
                guard let observation = probe(url, now), try LoginProbe.cookieFiles(url).map(LoginProbe.stamp) == signature else { return nil }
                entry = Entry(url: url, signature: signature, observedAt: now, observation: observation)
                return observation.signedIn
            } catch { entry = nil; return nil }
        }
    }

    /// Metadata only: polling never copies or queries the cookie database unless a rescan is needed.
    public static func publicationSignature(desktop: URL) -> [FileStamp?] {
        ["config.json", "config.json.journal", "Cookies", "Cookies-wal", "Cookies-journal"].map {
            try? stamp(desktop.appendingPathComponent($0))
        }
    }

    /// Read a bounded, stable private copy including committed WAL frames. SQLite never opens Claude's files.
    public static func signedIn(cookies url: URL, now: Date = Date()) -> Bool? {
        observation(cookies: url, now: now)?.signedIn
    }

    static func observation(cookies url: URL, now: Date) -> Observation? {
        do {
            try SafeFiles.validateAncestors(url)
            guard FileManager.default.fileExists(atPath: url.path) else { return Observation(signedIn: false) }
            let urls = cookieFiles(url)
            let before = try urls.map(stamp)
            var data: [Data?] = []
            for (file, version) in zip(urls, before) {
                data.append(version == nil ? nil : try SafeFiles.read(file, limit: 32 * 1024 * 1024))
            }
            guard try urls.map(stamp) == before, let database = data[0] else { return nil }
            // A hot rollback journal requires recovery; the owner must finish it.
            if let journal = data[2], journal.prefix(8).contains(where: { $0 != 0 }) { return nil }
            let result = observation(cookieData: database, walData: data[1], now: now)
            guard try urls.map(stamp) == before else { return nil }
            return result
        } catch { return nil }
    }

    private static func cookieFiles(_ url: URL) -> [URL] {
        [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-journal")]
    }

    private static func stamp(_ url: URL) throws -> FileStamp? {
        try SafeFiles.validateAncestors(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = FileHandle(fileDescriptor: try SafeFiles.openRead(url), closeOnDealloc: true)
        defer { try? handle.close() }
        return try SafeFiles.stamp(handle.fileDescriptor)
    }

    public static func signedIn(cookieData: Data, walData: Data? = nil, now: Date = Date()) -> Bool? {
        observation(cookieData: cookieData, walData: walData, now: now)?.signedIn
    }

    private static func observation(cookieData: Data, walData: Data?, now: Date) -> Observation? {
        guard cookieData.count <= 32 * 1024 * 1024, (walData?.count ?? 0) <= 32 * 1024 * 1024 else { return nil }
        // macOS standardizes /private/var back to the /var symlink. Use an exclusive OS temporary directory.
        var template = Array(FileManager.default.temporaryDirectory.appendingPathComponent("switch-probe-XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else { return nil }
        let folder = URL(fileURLWithPath: String(cString: template))
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            let file = folder.appendingPathComponent("Cookies")
            try writeCopy(cookieData, to: file)
            if let walData, !walData.isEmpty {
                try writeCopy(walData, to: folder.appendingPathComponent("Cookies-wal"))
            }
            return query(file, now: now)
        } catch { return nil }
    }

    private static func writeCopy(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SwitchError.unsafePath }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
    }

    private static func query(_ url: URL, now: Date) -> Observation? {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(db, 100)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT expires_utc FROM cookies WHERE host_key IN ('.claude.ai', 'claude.ai') AND name IN ('sessionKey', 'sessionKeyV3')"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        let current = Int64((now.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let expires = sqlite3_column_int64(statement, 0)
                if expires == 0 { return Observation(signedIn: true) }
                if expires > current {
                    return Observation(signedIn: true, validUntil: Date(timeIntervalSince1970: Double(expires) / 1_000_000 - 11_644_473_600))
                }
            case SQLITE_DONE: return Observation(signedIn: false)
            default: return nil
            }
        }
    }
}
