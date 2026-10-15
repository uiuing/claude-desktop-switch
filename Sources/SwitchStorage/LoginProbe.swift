import Foundation
import SQLite3
import SwitchCore

/// Local cookie evidence only. Absence is not proof of server-side revocation.
public enum LoginProbe {
    /// Metadata only: polling never copies or queries the cookie database unless a rescan is needed.
    public static func publicationSignature(desktop: URL) -> [FileStamp?] {
        ["config.json", "config.json.journal", "Cookies", "Cookies-wal", "Cookies-journal"].map {
            try? stamp(desktop.appendingPathComponent($0))
        }
    }

    /// Read a bounded, stable private copy including committed WAL frames. SQLite never opens Claude's files.
    public static func signedIn(cookies url: URL, now: Date = Date()) -> Bool? {
        do {
            try SafeFiles.validateAncestors(url)
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            let urls = [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-journal")]
            let before = try urls.map(stamp)
            var data: [Data?] = []
            for (file, version) in zip(urls, before) {
                data.append(version == nil ? nil : try SafeFiles.read(file, limit: 32 * 1024 * 1024))
            }
            guard try urls.map(stamp) == before, let database = data[0] else { return nil }
            // A hot rollback journal requires recovery; the owner must finish it.
            if let journal = data[2], journal.prefix(8).contains(where: { $0 != 0 }) { return nil }
            let result = signedIn(cookieData: database, walData: data[1], now: now)
            guard try urls.map(stamp) == before else { return nil }
            return result
        } catch { return nil }
    }

    private static func stamp(_ url: URL) throws -> FileStamp? {
        try SafeFiles.validateAncestors(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = FileHandle(fileDescriptor: try SafeFiles.openRead(url), closeOnDealloc: true)
        defer { try? handle.close() }
        return try SafeFiles.stamp(handle.fileDescriptor)
    }

    public static func signedIn(cookieData: Data, walData: Data? = nil, now: Date = Date()) -> Bool? {
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

    private static func query(_ url: URL, now: Date) -> Bool? {
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
                if expires == 0 || expires > current { return true }
            case SQLITE_DONE: return false
            default: return nil
            }
        }
    }
}
