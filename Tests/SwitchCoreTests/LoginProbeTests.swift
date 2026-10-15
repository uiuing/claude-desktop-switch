import XCTest
import SQLite3
@testable import SwitchStorage

final class LoginProbeTests: XCTestCase {
    private func cookies(_ rows: [(host: String, name: String, expires: Date?)]) throws -> URL {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/transfer-fixtures/probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Cookies")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE cookies (host_key TEXT, name TEXT, expires_utc INTEGER)", nil, nil, nil), SQLITE_OK)
        for row in rows {
            let expires = row.expires.map { Int64(($0.timeIntervalSince1970 + 11_644_473_600) * 1_000_000) } ?? 0
            let sql = "INSERT INTO cookies VALUES ('\(row.host)', '\(row.name)', \(expires))"
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
        return url
    }

    func testSessionCookieMeansSignedIn() throws {
        let url = try cookies([(".claude.ai", "sessionKey", Date().addingTimeInterval(86_400)), (".claude.ai", "lastActiveOrg", nil)])
        XCTAssertEqual(LoginProbe.signedIn(cookies: url), true)
        XCTAssertEqual(LoginProbe.signedIn(cookieData: try Data(contentsOf: url)), true)
    }

    func testSignedOutStoreKeepsOnlyAnonymousCookies() throws {
        let url = try cookies([(".claude.ai", "lastActiveOrg", nil), ("claude.ai", "anthropic-device-id", Date().addingTimeInterval(86_400))])
        XCTAssertEqual(LoginProbe.signedIn(cookies: url), false)
    }

    func testExpiredSessionIsSignedOut() throws {
        let url = try cookies([(".claude.ai", "sessionKey", Date().addingTimeInterval(-60))])
        XCTAssertEqual(LoginProbe.signedIn(cookies: url), false)
    }

    func testMissingStoreIsSignedOutAndGarbageIsUnknown() throws {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/transfer-fixtures")
        XCTAssertEqual(LoginProbe.signedIn(cookies: folder.appendingPathComponent("none-\(UUID().uuidString)")), false)
        XCTAssertNil(LoginProbe.signedIn(cookieData: Data("not a database".utf8)))
    }

    func testCommittedWALIsIncludedWithoutChangingOriginalFiles() throws {
        let url = try cookies([])
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; INSERT INTO cookies VALUES ('.claude.ai','sessionKeyV3',0)", nil, nil, nil), SQLITE_OK)
        let wal = URL(fileURLWithPath: url.path + "-wal")
        let databaseBefore = try Data(contentsOf: url), walBefore = try Data(contentsOf: wal)
        XCTAssertFalse(walBefore.isEmpty)
        XCTAssertEqual(LoginProbe.signedIn(cookies: url), true)
        XCTAssertEqual(LoginProbe.signedIn(cookieData: databaseBefore, walData: walBefore), true)
        XCTAssertEqual(try Data(contentsOf: url), databaseBefore)
        XCTAssertEqual(try Data(contentsOf: wal), walBefore)
        XCTAssertEqual(sqlite3_exec(db, "DELETE FROM cookies", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(LoginProbe.signedIn(cookies: url), false)
    }

    func testSymlinkAndHotRollbackJournalAreUnknown() throws {
        let url = try cookies([(".claude.ai", "sessionKey", nil)])
        let link = url.deletingLastPathComponent().appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertNil(LoginProbe.signedIn(cookies: link))
        try Data(repeating: 1, count: 64).write(to: URL(fileURLWithPath: url.path + "-journal"))
        XCTAssertNil(LoginProbe.signedIn(cookies: url))
    }
}
