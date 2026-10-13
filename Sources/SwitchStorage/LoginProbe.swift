import Foundation
import SQLite3

/// Whether a Claude Desktop login is signed in, judged by the claude.ai session cookie.
/// Signing out, in Claude or because the server rejected the login, deletes that cookie;
/// `lastKnownAccountUuid` in config.json stays behind and is not evidence of a login.
public enum LoginProbe {
    /// nil when the cookie store cannot be read right now.
    public static func signedIn(cookies url: URL, now: Date = Date()) -> Bool? {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        // Chromium holds the database in exclusive locking mode while Claude runs; only an immutable read gets in.
        let path = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2("file:" + path + "?mode=ro&immutable=1", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
        else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT expires_utc FROM cookies WHERE host_key IN ('.claude.ai', 'claude.ai') AND name IN ('sessionKey', 'sessionKeyV3')"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        // Chromium counts microseconds since 1601-01-01; 0 marks a cookie that lasts for the browsing session.
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

    /// The same check on a cookie store held in memory, such as one inside a saved snapshot.
    public static func signedIn(cookieData: Data, now: Date = Date()) -> Bool? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("switch-probe-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let file = folder.appendingPathComponent("Cookies")
            try cookieData.write(to: file, options: [.atomic])
            return signedIn(cookies: file, now: now)
        } catch { return nil }
    }
}
