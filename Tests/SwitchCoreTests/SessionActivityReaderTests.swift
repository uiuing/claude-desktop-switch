import XCTest
import SwitchCore
@testable import SwitchStorage

final class SessionActivityReaderTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let account = "0a1b2c3d-1111-4aaa-8bbb-000000000001"
    private let other = "1a1b2c3d-2222-4aaa-8bbb-000000000002"
    private let org = "2a1b2c3d-3333-4aaa-8bbb-000000000003"
    private let cli = "3a1b2c3d-4444-4aaa-8bbb-000000000004"
    private let session = "local_4a1b2c3d-5555-4aaa-8bbb-000000000005"
    private func fixture() throws -> (URL, SessionActivityReader) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/activity-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, SessionActivityReader(desktop: root.appendingPathComponent("desktop"), projects: root.appendingPathComponent("projects")))
    }
    private func write(_ file: URL, count: Int, at date: Date) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Invalid UTF-8 verifies that the activity reader only needs metadata, never a decoded body.
        try Data(repeating: 0xff, count: count).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    }
    private func conversation(owner: String? = nil) -> Conversation {
        .init(id: session, sessionID: session, accountID: owner ?? account, organizationID: org,
              title: "Fixture", kind: .code, modifiedAt: base, recordRelativePath: "fixture.json", cliSessionID: cli)
    }
    private var accounts: [Account] { [Account(id: account, organizationID: org), Account(id: other, organizationID: org)] }
    private func scan(_ reader: SessionActivityReader, sessions: [Conversation], offset: Double = 0) async -> SessionActivityReader.Observation {
        await reader.scan(accountID: account, organizationID: org, accounts: accounts, conversations: sessions, now: base.addingTimeInterval(offset))
    }
    func testOldRecordsDoNotCountAndInternalChangesAreCountedOnce() async throws {
        let (root, reader) = try fixture()
        let file = root.appendingPathComponent("projects/project/" + cli + ".jsonl")
        try write(file, count: 10, at: base.addingTimeInterval(-3600))
        let initial = await scan(reader, sessions: [conversation()])
        XCTAssertFalse(initial.changed); XCTAssertTrue(initial.complete)
        try write(file, count: 20, at: base.addingTimeInterval(60))
        let changed = await scan(reader, sessions: [conversation()], offset: 60)
        XCTAssertTrue(changed.changed); XCTAssertTrue(changed.complete)
        let repeated = await scan(reader, sessions: [conversation()], offset: 120)
        XCTAssertFalse(repeated.changed)
    }
    func testTitlesAndUnrelatedTranscriptsDoNotCountButSubagentsDo() async throws {
        let (root, reader) = try fixture()
        let file = root.appendingPathComponent("projects/project/" + cli + ".jsonl")
        try write(file, count: 10, at: base.addingTimeInterval(-3600))
        _ = await scan(reader, sessions: [conversation()])
        try write(root.appendingPathComponent("desktop/fixture.json"), count: 30, at: base.addingTimeInterval(60))
        try write(root.appendingPathComponent("projects/project/unrelated.jsonl"), count: 30, at: base.addingTimeInterval(60))
        let unrelated = await scan(reader, sessions: [conversation()], offset: 60)
        XCTAssertFalse(unrelated.changed)
        try write(root.appendingPathComponent("projects/project/" + cli + "/subagents/agent-fixture.jsonl"), count: 30, at: base.addingTimeInterval(120))
        let child = await scan(reader, sessions: [conversation()], offset: 120)
        XCTAssertTrue(child.changed)
    }
    func testSharedTranscriptHasAmbiguousOwnershipAndIsNotAttributed() async throws {
        let (root, reader) = try fixture()
        try write(root.appendingPathComponent("projects/project/" + cli + ".jsonl"), count: 10, at: base)
        let result = await scan(reader, sessions: [conversation(), conversation(owner: other)])
        XCTAssertFalse(result.changed); XCTAssertFalse(result.complete)
    }
    func testCoworkAgentAuditAndNestedTranscriptOnlyWithinCurrentAccount() async throws {
        let (root, reader) = try fixture()
        let folder = root.appendingPathComponent("desktop/local-agent-mode-sessions/" + account + "/" + org + "/agent/" + session)
        try write(folder.appendingPathComponent("audit.jsonl"), count: 10, at: base.addingTimeInterval(-3600))
        _ = await scan(reader, sessions: [])
        try write(folder.appendingPathComponent("outputs/output.jsonl"), count: 10, at: base.addingTimeInterval(60))
        try write(root.appendingPathComponent("desktop/local-agent-mode-sessions/" + other + "/" + org + "/" + session + "/audit.jsonl"), count: 10, at: base.addingTimeInterval(60))
        let unrelated = await scan(reader, sessions: [], offset: 60)
        XCTAssertFalse(unrelated.changed)
        try write(folder.appendingPathComponent(".claude/projects/project/" + cli + ".jsonl"), count: 10, at: base.addingTimeInterval(120))
        let internalChange = await scan(reader, sessions: [], offset: 120)
        XCTAssertTrue(internalChange.changed); XCTAssertTrue(internalChange.complete)
    }
    func testMissingTranscriptAndSymlinkNeverBecomeConfirmedInactivity() async throws {
        let (root, reader) = try fixture()
        let missing = await scan(reader, sessions: [conversation()])
        XCTAssertFalse(missing.complete)
        let target = root.appendingPathComponent("elsewhere/" + cli + ".jsonl")
        try write(target, count: 10, at: base.addingTimeInterval(60))
        let link = root.appendingPathComponent("projects/project")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target.deletingLastPathComponent())
        let result = await scan(reader, sessions: [conversation()], offset: 60)
        XCTAssertFalse(result.changed); XCTAssertFalse(result.complete)
    }
}
