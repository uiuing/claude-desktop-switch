import XCTest
import SQLite3
import SwitchCore
@testable import SwitchStorage

final class LocalReaderTests: XCTestCase {
    private let account = "0a1b2c3d-1111-4aaa-8bbb-000000000001"
    private let desktopOrganization = "0a1b2c3d-3333-4aaa-8bbb-000000000003"
    private let codeOrganization = "0a1b2c3d-5555-4aaa-8bbb-000000000005"
    private let verifiedOrganization = "0a1b2c3d-6666-4aaa-8bbb-000000000006"

    /// A signed-in Desktop login and a Claude Code login of the same account in another organization.
    private func reader(sessionsIn organization: String?) throws -> LocalReader {
        let home = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/transfer-fixtures/reader-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let desktop = home.appendingPathComponent("Library/Application Support/Claude")
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        try Data(#"{"lastKnownAccountUuid":"\#(account)"}"#.utf8).write(to: desktop.appendingPathComponent("config.json"))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(desktop.appendingPathComponent("Cookies").path, &db), SQLITE_OK)
        let expires = Int64((Date().addingTimeInterval(86_400).timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        sqlite3_exec(db, "CREATE TABLE cookies (host_key TEXT, name TEXT, expires_utc INTEGER)", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO cookies VALUES ('.claude.ai', 'sessionKey', \(expires))", nil, nil, nil)
        sqlite3_close(db)
        if let organization {
            let folder = desktop.appendingPathComponent("claude-code-sessions/\(account)/\(organization)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let session = "0a1b2c3d-4444-4aaa-8bbb-000000000004"
            try Data(#"{"sessionId":"\#(session)","cliSessionId":"0a1b2c3d-7777-4aaa-8bbb-000000000007","title":"Fixture","cwd":"/fixture"}"#.utf8)
                .write(to: folder.appendingPathComponent(session + ".json"))
        }
        let code = home.appendingPathComponent(".claude.json")
        try Data(#"{"projects":{"/fixture":{"history":[]}},"oauthAccount":{"accountUuid":"\#(account)","emailAddress":"mi•••el@gmail.com","organizationUuid":"\#(codeOrganization)"}}"#.utf8)
            .write(to: code)
        return LocalReader(desktop: desktop, codeConfig: code)
    }

    func testDesktopSessionsDecideTheOrganizationOverClaudeCode() async throws {
        let found = try await reader(sessionsIn: desktopOrganization).scan().accounts.first { $0.id == account }
        XCTAssertEqual(found?.organizationID, desktopOrganization)
        XCTAssertEqual(found?.email, "mi•••el@gmail.com")
    }

    func testClaudeCodeOrganizationOnlyFillsAGap() async throws {
        let found = try await reader(sessionsIn: nil).scan().accounts.first { $0.id == account }
        XCTAssertEqual(found?.organizationID, codeOrganization)
    }

    func testOrganizationConfirmedOnlineWins() async throws {
        let inventory = try await reader(sessionsIn: desktopOrganization).scan(verifiedOrganizations: [account: verifiedOrganization])
        XCTAssertEqual(inventory.accounts.first { $0.id == account }?.organizationID, verifiedOrganization)
    }
}
