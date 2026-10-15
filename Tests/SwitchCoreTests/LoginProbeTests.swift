import XCTest
import SQLite3
@testable import SwitchStorage

final class LoginProbeTests: XCTestCase {
    private final class ReadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func record() { lock.lock(); defer { lock.unlock() }; count += 1 }
    }
    private func cache(_ reads: ReadCounter) -> LoginProbe.Cache {
        LoginProbe.Cache { url, now in
            reads.record()
            return LoginProbe.observation(cookies: url, now: now)
        }
    }
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

    func testPollingCacheReusesStableEvidenceWithBoundedAge() throws {
        let url = try cookies([(".claude.ai", "sessionKey", nil)])
        let reads = ReadCounter(); var cached = cache(reads)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for tick in 0..<120 {
            XCTAssertEqual(cached.signedIn(cookies: url, now: now.addingTimeInterval(Double(tick) / 2)), true)
        }
        XCTAssertEqual(reads.value, 1)
        XCTAssertEqual(cached.signedIn(cookies: url, now: now.addingTimeInterval(60)), true)
        XCTAssertEqual(reads.value, 2)
        cached.invalidate()
        XCTAssertEqual(cached.signedIn(cookies: url, now: now.addingTimeInterval(61)), true)
        XCTAssertEqual(reads.value, 3)
    }

    func testPollingCacheExpiresWithoutFileChangesAndHandlesClockRollback() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let url = try cookies([(".claude.ai", "sessionKey", now.addingTimeInterval(2)),
                               ("claude.ai", "sessionKeyV3", now.addingTimeInterval(5))])
        let reads = ReadCounter(); var cached = cache(reads)
        for seconds: TimeInterval in [0, 1, 2, 4, 5, 6] {
            XCTAssertEqual(cached.signedIn(cookies: url, now: now.addingTimeInterval(seconds)), seconds < 5)
        }
        XCTAssertEqual(reads.value, 3)
        XCTAssertEqual(cached.signedIn(cookies: url, now: now.addingTimeInterval(1)), true)
        XCTAssertEqual(reads.value, 4)
    }

    func testPollingCacheObservesCommittedWALSignInAndSignOut() throws {
        let url = try cookies([])
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; INSERT INTO cookies VALUES ('.claude.ai','lastActiveOrg',0)", nil, nil, nil), SQLITE_OK)
        let reads = ReadCounter(); var cached = cache(reads)
        XCTAssertEqual(cached.signedIn(cookies: url), false)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO cookies VALUES ('.claude.ai','sessionKeyV3',0)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(cached.signedIn(cookies: url), true)
        XCTAssertEqual(sqlite3_exec(db, "DELETE FROM cookies", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(cached.signedIn(cookies: url), false)
        XCTAssertEqual(reads.value, 3)
    }

    func testPollingCacheRejectsChangedMalformedAndUnsafeFiles() throws {
        let url = try cookies([(".claude.ai", "sessionKey", nil)])
        let original = try Data(contentsOf: url)
        let reads = ReadCounter(); var cached = cache(reads)
        XCTAssertEqual(cached.signedIn(cookies: url), true)
        try Data("not a database".utf8).write(to: url, options: .atomic)
        XCTAssertNil(cached.signedIn(cookies: url)); XCTAssertNil(cached.signedIn(cookies: url))
        XCTAssertEqual(reads.value, 3)
        try original.write(to: url, options: .atomic)
        XCTAssertEqual(cached.signedIn(cookies: url), true)
        let wal = URL(fileURLWithPath: url.path + "-wal")
        try FileManager.default.createSymbolicLink(at: wal, withDestinationURL: url)
        XCTAssertNil(cached.signedIn(cookies: url))
        try FileManager.default.removeItem(at: wal)
        XCTAssertEqual(cached.signedIn(cookies: url), true)
        XCTAssertEqual(reads.value, 5)
        let journal = URL(fileURLWithPath: url.path + "-journal")
        try Data(repeating: 1, count: 64).write(to: journal)
        XCTAssertNil(cached.signedIn(cookies: url))
        try FileManager.default.removeItem(at: journal)
        XCTAssertEqual(cached.signedIn(cookies: url), true)
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(cached.signedIn(cookies: url), false)
        try original.write(to: url)
        XCTAssertEqual(cached.signedIn(cookies: url), true)
    }

    func testPollingCacheDiscardsEvidenceThatChangesDuringRead() throws {
        let url = try cookies([(".claude.ai", "sessionKey", nil)])
        let reads = ReadCounter()
        var cached = LoginProbe.Cache { url, now in
            reads.record()
            let result = LoginProbe.observation(cookies: url, now: now)
            if reads.value == 1 {
                try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(10)], ofItemAtPath: url.path)
            }
            return result
        }
        XCTAssertNil(cached.signedIn(cookies: url))
        XCTAssertEqual(cached.signedIn(cookies: url), true)
        XCTAssertEqual(reads.value, 2)
        let other = try cookies([])
        XCTAssertEqual(cached.signedIn(cookies: other), false)
        XCTAssertEqual(reads.value, 3)
    }
}
