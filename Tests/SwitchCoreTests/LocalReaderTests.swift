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
        return LocalReader(desktop: desktop, codeConfig: code, projects: home.appendingPathComponent(".claude/projects"))
    }

    private func setActivity(_ reader: LocalReader, last: Date, updated: Date? = nil) async throws {
        let desktop = await reader.desktop
        let file = desktop.appendingPathComponent("claude-code-sessions/\(account)/\(desktopOrganization)/0a1b2c3d-4444-4aaa-8bbb-000000000004.json")
        var record = try XCTUnwrap(SafeFiles.json(file).object)
        record["lastActivityAt"] = .number(last.timeIntervalSince1970 * 1000)
        record["updatedAt"] = updated.map { .number($0.timeIntervalSince1970 * 1000) }
        try JSONEncoder().encode(JSONValue.object(record)).write(to: file)
    }

    @discardableResult
    private func transcript(_ reader: LocalReader, project: String = "fixture", name: String? = nil,
                            at date: Date, empty: Bool = false) async throws -> URL {
        let projects = await reader.projects
        let file = try XCTUnwrap(projects).appendingPathComponent(project + "/" + (name ?? "0a1b2c3d-7777-4aaa-8bbb-000000000007.jsonl"))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The activity timestamp must require only metadata, not transcript contents.
        try Data(repeating: 0xff, count: empty ? 0 : 10).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        return file
    }

    func testTranscriptActivityUpdatesCachedIndexAndSwitchPreselection() async throws {
        let reader = try reader(sessionsIn: desktopOrganization), now = Date()
        let old = now.addingTimeInterval(-3600), recent = now.addingTimeInterval(-30)
        try await setActivity(reader, last: old)
        try await transcript(reader, at: old)
        let initial = try await reader.scan()
        XCTAssertEqual(initial.conversations.first?.modifiedAt.timeIntervalSince1970 ?? 0, old.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertFalse(try XCTUnwrap(initial.conversations.first).modifiedAt > now.addingTimeInterval(-300))
        try await transcript(reader, at: recent)
        let updated = try await reader.scan()
        let session = try XCTUnwrap(updated.conversations.first)
        XCTAssertEqual(session.modifiedAt.timeIntervalSince1970, recent.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertTrue(SessionLibrary.recentlyActiveForSwitch(session, activeAccountID: account, now: now))
        XCTAssertTrue(updated.warnings.isEmpty)
    }

    func testNewestIndexTimestampWinsWithoutUsingRewriteTimeAsActivity() async throws {
        let reader = try reader(sessionsIn: desktopOrganization)
        let old = Date().addingTimeInterval(-7200), newer = old.addingTimeInterval(600)
        try await transcript(reader, at: old)
        for (last, updated) in [(old, newer), (newer, old)] {
            try await setActivity(reader, last: last, updated: updated)
            let result = try await reader.scan()
            XCTAssertEqual(result.conversations.first?.modifiedAt.timeIntervalSince1970 ?? 0, newer.timeIntervalSince1970, accuracy: 0.001)
        }
    }

    func testNativeSubagentActivityUpdatesWithoutAnIndexOrMainTranscriptChange() async throws {
        let reader = try reader(sessionsIn: desktopOrganization), now = Date()
        let old = now.addingTimeInterval(-3600), recent = now.addingTimeInterval(-30)
        try await setActivity(reader, last: old)
        try await transcript(reader, at: old)
        let initial = try await reader.scan()
        XCTAssertEqual(initial.conversations.first?.modifiedAt.timeIntervalSince1970 ?? 0, old.timeIntervalSince1970, accuracy: 0.001)
        let agents = "0a1b2c3d-7777-4aaa-8bbb-000000000007/subagents/"
        try await transcript(reader, name: agents + "agent-fixture.jsonl", at: recent)
        try await transcript(reader, name: agents + "agent-old.superseded-fixture.jsonl", at: now)
        let result = try await reader.scan()
        XCTAssertEqual(result.conversations.first?.modifiedAt.timeIntervalSince1970 ?? 0, recent.timeIntervalSince1970, accuracy: 0.001)
    }

    func testSharedTranscriptDoesNotMakeAnInactiveAccountCopyRecent() async throws {
        let reader = try reader(sessionsIn: desktopOrganization), now = Date()
        let old = now.addingTimeInterval(-3600), recent = now.addingTimeInterval(-30)
        try await setActivity(reader, last: old)
        let desktop = await reader.desktop
        let other = "0a1b2c3d-9999-4aaa-8bbb-000000000009", session = "0a1b2c3d-4444-4aaa-8bbb-000000000004.json"
        let source = desktop.appendingPathComponent("claude-code-sessions/\(account)/\(desktopOrganization)/" + session)
        let target = desktop.appendingPathComponent("claude-code-sessions/\(other)/\(desktopOrganization)/" + session)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: target)
        try await transcript(reader, at: recent)
        let inventory = try await reader.scan()
        XCTAssertEqual(inventory.conversations.first { $0.accountID == account }?.modifiedAt.timeIntervalSince1970 ?? 0,
                       recent.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(inventory.conversations.first { $0.accountID == other }?.modifiedAt.timeIntervalSince1970 ?? 0,
                       old.timeIntervalSince1970, accuracy: 0.001)
    }

    func testUnrelatedAmbiguousAndUnsafeTranscriptsCannotMakeASessionRecent() async throws {
        let reader = try reader(sessionsIn: desktopOrganization), now = Date()
        let old = now.addingTimeInterval(-3600)
        try await setActivity(reader, last: old)
        try await transcript(reader, name: "0a1b2c3d-8888-4aaa-8bbb-000000000008.jsonl", at: now.addingTimeInterval(-10))
        let target = try await transcript(reader, project: "first", at: now.addingTimeInterval(-20))
        let duplicate = try await transcript(reader, project: "second", at: now.addingTimeInterval(-30))
        for phase in 0..<4 {
            if phase == 1 {
                try FileManager.default.removeItem(at: duplicate)
                try FileManager.default.createSymbolicLink(at: duplicate, withDestinationURL: target)
                try FileManager.default.removeItem(at: target)
            } else if phase == 2 {
                try await transcript(reader, project: "first", at: now.addingTimeInterval(3600))
            } else if phase == 3 {
                try await transcript(reader, project: "first", at: now.addingTimeInterval(-10), empty: true)
            }
            let result = try await reader.scan()
            XCTAssertEqual(result.conversations.first?.modifiedAt.timeIntervalSince1970 ?? 0, old.timeIntervalSince1970, accuracy: 0.001, "phase \(phase)")
        }
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

    func testDesktopEmailCacheUpdatesThroughExistingScanAndOutranksCodeFallback() async throws {
        let reader = try reader(sessionsIn: desktopOrganization)
        let folder = await reader.desktop.appendingPathComponent(DesktopProfile.blobDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func string(_ value: String) -> [UInt8] { [0x22, UInt8(value.utf8.count)] + Array(value.utf8) }
        let file = folder.appendingPathComponent("1")
        for email in ["fixture-1@fixture.invalid", "fixture-2@fixture.invalid"] {
            try Data(string("uuid") + string(account) + string("email_address") + string(email)).write(to: file)
            let inventory = try await reader.scan()
            XCTAssertEqual(inventory.accounts.first { $0.id == account }?.email, email)
            XCTAssertEqual(inventory.desktopEmails[account], email)
        }
    }

    func testOrganizationConfirmedOnlineWins() async throws {
        let inventory = try await reader(sessionsIn: desktopOrganization).scan(verifiedOrganizations: [account: verifiedOrganization])
        XCTAssertEqual(inventory.accounts.first { $0.id == account }?.organizationID, verifiedOrganization)
    }

    func testLocalQuotaHistoryNeverSuppliesQuota() async throws {
        let reader = try reader(sessionsIn: desktopOrganization)
        let history = #"{"samples":[{"t":1800000000,"org":"\#(desktopOrganization)","u":{"fh":99,"sd":90}}]}"#
        let desktop = await reader.desktop
        try Data(history.utf8).write(to: desktop.appendingPathComponent("plan-usage-history.json"))
        let inventory = try await reader.scan()
        XCTAssertNil(inventory.usage)
        XCTAssertTrue(inventory.cachedUsage.isEmpty)
        XCTAssertTrue(inventory.warnings.isEmpty)
    }
}
