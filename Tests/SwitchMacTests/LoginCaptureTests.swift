import XCTest
import SQLite3
import SwitchCore
import SwitchStorage
@testable import SwitchMac

final class LoginCaptureTests: XCTestCase {
    private let account = "0a1b2c3d-1111-4aaa-8bbb-000000000001"

    private func fixture(signedIn: Bool) throws -> (MacEnvironment, OpaquePointer?) {
        let home = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/transfer-fixtures/capture-\(UUID().uuidString)")
        let env = MacEnvironment(home: home)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: env.desktop.appendingPathComponent("Local Storage"), withIntermediateDirectories: true)
        try Data(#"{"lastKnownAccountUuid":"\#(account)","oauth:tokenCacheV2":"fixture-cache"}"#.utf8).write(to: env.desktop.appendingPathComponent("config.json"))
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(env.desktop.appendingPathComponent("Cookies").path, &database), SQLITE_OK)
        let connection = database
        addTeardownBlock { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE cookies (host_key TEXT, name TEXT, expires_utc INTEGER)", nil, nil, nil), SQLITE_OK)
        if signedIn {
            XCTAssertEqual(sqlite3_exec(database, "INSERT INTO cookies VALUES ('.claude.ai','sessionKey',0)", nil, nil, nil), SQLITE_OK)
        }
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0", nil, nil, nil), SQLITE_OK)
        return (env, database)
    }

    func testCaptureIncludesLoginCommittedOnlyInWAL() async throws {
        let (env, database) = try fixture(signedIn: false)
        XCTAssertEqual(sqlite3_exec(database, "INSERT INTO cookies VALUES ('.claude.ai','sessionKeyV3',0)", nil, nil, nil), SQLITE_OK)
        let cookies = env.desktop.appendingPathComponent("Cookies"), wal = env.desktop.appendingPathComponent("Cookies-wal")
        let before = try Data(contentsOf: cookies), walBefore = try Data(contentsOf: wal)
        XCTAssertNotEqual(LoginProbe.signedIn(cookieData: before), true)
        XCTAssertEqual(env.signedIn(), true)

        let engine = SwitchEngine(environment: env, vault: CredentialVault(root: env.root.appendingPathComponent("vault")))
        let snapshot = try await engine.capture(version: "0.14.2")

        XCTAssertEqual(snapshot.accountID, account)
        XCTAssertEqual(snapshot.files.first { $0.path == "Cookies" }?.data, before)
        XCTAssertEqual(snapshot.files.first { $0.path == "Cookies-wal" }?.data, walBefore)
        XCTAssertEqual(try Data(contentsOf: cookies), before)
        XCTAssertEqual(try Data(contentsOf: wal), walBefore)
    }

    func testCaptureRejectsLogoutCommittedOnlyInWAL() async throws {
        let (env, database) = try fixture(signedIn: true)
        XCTAssertEqual(sqlite3_exec(database, "DELETE FROM cookies", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(env.signedIn(), false)

        let engine = SwitchEngine(environment: env, vault: CredentialVault(root: env.root.appendingPathComponent("vault")))
        do {
            _ = try await engine.capture(version: "0.14.2")
            XCTFail("A captured logout must not be saved as a signed-in login")
        } catch SwitchError.blocked { }
    }
}
