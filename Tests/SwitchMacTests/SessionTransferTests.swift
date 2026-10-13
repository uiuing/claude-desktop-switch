import Foundation
import XCTest
import SwitchCore
import SwitchStorage
@testable import SwitchMac

final class SessionTransferTests: XCTestCase {
    struct Fixture {
        let env: MacEnvironment
        let session: Conversation
        let target: Account
        let source: URL
        let destination: URL
        let transcript: URL
        let sourceData: Data
        let destinationData: Data
        var destinationRelative: String { "claude-code-sessions/\(target.id)/\(target.organizationID!)/\(session.sessionID).json" }
        func changes(_ mode: SessionTransferMode = .move) throws -> [MigrationChange] {
            try MigrationBuilder.changes(sessions: [session], target: target, environment: env,
                expectedDigests: [session.id: digest(sourceData)],
                destinations: [destinationRelative: .sha256(digest(destinationData))], modes: [session.id: mode])
        }
        func transaction(_ changes: [MigrationChange]) throws -> FileTransaction {
            let plan = OperationPlan(kind: .migrate, sourceAccountID: session.accountID, targetAccountID: target.id,
                                     configDigest: "fixture", steps: [])
            let transaction = try FileTransaction(parent: env.root.appendingPathComponent("transactions"), live: env.desktop, plan: plan)
            for change in changes { try transaction.stage(relative: change.relative, data: change.data, expectation: change.expectation) }
            return transaction
        }
    }
    private func fixture() throws -> Fixture {
        let home = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/transfer-fixtures/\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let env = MacEnvironment(home: home)
        let owner = UUID().uuidString.lowercased(), org = UUID().uuidString.lowercased()
        let sid = UUID().uuidString.lowercased(), cli = UUID().uuidString.lowercased()
        let target = Account(id: UUID().uuidString.lowercased(), organizationID: UUID().uuidString.lowercased())
        let relative = "claude-code-sessions/\(owner)/\(org)/\(sid).json"
        let session = Conversation(id: owner + "/" + org + "/code/" + sid, sessionID: sid, accountID: owner,
            organizationID: org, title: "Latest", kind: .code, modifiedAt: Date(), recordRelativePath: relative, cliSessionID: cli)
        let source = env.desktop.appendingPathComponent(relative)
        let destination = env.desktop.appendingPathComponent("claude-code-sessions/\(target.id)/\(target.organizationID!)/\(sid).json")
        let transcript = env.projects.appendingPathComponent("fixture-project/\(cli).jsonl")
        let sourceData = try JSONSerialization.data(withJSONObject: ["sessionId": sid, "cliSessionId": cli, "cwd": "/fixture/project",
            "title": "Latest", "permissionMode": "bypassPermissions", "remoteControl": true], options: .sortedKeys)
        let destinationData = try JSONSerialization.data(withJSONObject: ["sessionId": sid, "cliSessionId": cli,
            "cwd": "/old/project", "title": "Old"], options: .sortedKeys)
        for (url, data) in [(source, sourceData), (destination, destinationData), (transcript, Data("shared transcript\n".utf8))] {
            try SafeFiles.privateDirectory(url.deletingLastPathComponent()); try SafeFiles.atomicWrite(data, to: url)
        }
        try SafeFiles.atomicWrite(JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": owner]), to: env.desktop.appendingPathComponent("config.json"))
        return Fixture(env: env, session: session, target: target, source: source, destination: destination,
                       transcript: transcript, sourceData: sourceData, destinationData: destinationData)
    }

    func testPreviewDefaultsToMoveAndCapturesExistingTarget() async throws {
        let f = try fixture(), vault = CredentialVault(root: f.env.root.appendingPathComponent("vault"))
        let engine = SwitchEngine(environment: f.env, vault: vault)
        let plan = try await engine.prepare(kind: .migrate, target: f.target, sessions: [f.session])
        XCTAssertEqual(plan.transferMode(for: f.session.id), .move)
        XCTAssertEqual(plan.destinationExpectations[f.destinationRelative], .sha256(digest(f.destinationData)))
        XCTAssertEqual(try Data(contentsOf: f.source), f.sourceData)
        XCTAssertEqual(try Data(contentsOf: f.destination), f.destinationData)
    }

    func testMoveAndCopyReplaceSameSessionAndKeepSharedTranscript() async throws {
        try XCTSkipUnless(BuildAccess.allowsClaudeWrites, "Run isolated fixture tests with CLAUDE_WRITE_ENABLED")
        for mode in SessionTransferMode.allCases {
            let f = try fixture(), changes = try f.changes(mode), transaction = try f.transaction(changes)
            XCTAssertEqual(changes.first?.relative, f.destinationRelative)
            try await transaction.apply { }
            try transaction.commit()
            XCTAssertEqual(FileManager.default.fileExists(atPath: f.source.path), mode == .copy)
            let updated = try SafeFiles.json(f.destination)
            XCTAssertEqual(updated["title"].string, "Latest")
            XCTAssertEqual(updated["permissionMode"].string, "default")
            XCTAssertNil(updated["remoteControl"].bool)
            XCTAssertEqual(try Data(contentsOf: f.transcript), Data("shared transcript\n".utf8))
            XCTAssertEqual(try Data(contentsOf: transaction.root.appendingPathComponent("originals/" + f.destinationRelative)), f.destinationData)
        }
    }

    func testRestartRecoveryRestoresBothSidesAfterMove() async throws {
        try XCTSkipUnless(BuildAccess.allowsClaudeWrites, "Run isolated fixture tests with CLAUDE_WRITE_ENABLED")
        let f = try fixture(), transaction = try f.transaction(f.changes())
        try await transaction.apply { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.source.path))
        let recovered = try FileTransaction(existing: transaction.root, live: f.env.desktop)
        try await recovered.rollback { }
        XCTAssertEqual(try Data(contentsOf: f.source), f.sourceData)
        XCTAssertEqual(try Data(contentsOf: f.destination), f.destinationData)
    }

    func testTargetChangesAfterPreviewAreRejected() throws {
        let f = try fixture()
        try SafeFiles.atomicWrite(Data("changed target".utf8), to: f.destination)
        XCTAssertThrowsError(try f.changes())
        XCTAssertEqual(try Data(contentsOf: f.source), f.sourceData)
    }

    func testSourceChangesBeforeRemovalRollBackDestinationAndPreserveNewSource() async throws {
        try XCTSkipUnless(BuildAccess.allowsClaudeWrites, "Run isolated fixture tests with CLAUDE_WRITE_ENABLED")
        let f = try fixture(), transaction = try f.transaction(f.changes())
        let newer = Data("source changed after staging".utf8)
        try SafeFiles.atomicWrite(newer, to: f.source)
        do { try await transaction.apply { }; XCTFail("Source digest must prevent removal") }
        catch { try await transaction.rollback { } }
        XCTAssertEqual(try Data(contentsOf: f.source), newer)
        XCTAssertEqual(try Data(contentsOf: f.destination), f.destinationData)
    }

    func testTargetChangesAfterStagingAreRejectedBeforeAnyRemoval() async throws {
        try XCTSkipUnless(BuildAccess.allowsClaudeWrites, "Run isolated fixture tests with CLAUDE_WRITE_ENABLED")
        let f = try fixture(), transaction = try f.transaction(f.changes())
        let newer = Data("new target after staging".utf8)
        try SafeFiles.atomicWrite(newer, to: f.destination)
        do { try await transaction.apply { }; XCTFail("Target must be rechecked immediately before overwrite") }
        catch { try await transaction.rollback { } }
        XCTAssertEqual(try Data(contentsOf: f.source), f.sourceData)
        XCTAssertEqual(try Data(contentsOf: f.destination), newer)
    }

    func testMixedBatchInstallsAllTargetsBeforeRemovingOnlyMoveSources() async throws {
        try XCTSkipUnless(BuildAccess.allowsClaudeWrites, "Run isolated fixture tests with CLAUDE_WRITE_ENABLED")
        let f = try fixture()
        var second = f.session
        second.sessionID = UUID().uuidString.lowercased()
        second.id = second.accountID + "/" + second.organizationID + "/code/" + second.sessionID
        second.recordRelativePath = "claude-code-sessions/\(second.accountID)/\(second.organizationID)/\(second.sessionID).json"
        var raw = try JSONDecoder().decode(JSONValue.self, from: f.sourceData).object!
        raw["sessionId"] = .string(second.sessionID)
        let bytes = try JSONEncoder().encode(JSONValue.object(raw))
        let secondSource = f.env.desktop.appendingPathComponent(second.recordRelativePath)
        try SafeFiles.atomicWrite(bytes, to: secondSource)
        let secondRelative = try MigrationBuilder.destinationRelative(session: second, target: f.target)
        let changes = try MigrationBuilder.changes(sessions: [f.session, second], target: f.target, environment: f.env,
            expectedDigests: [f.session.id: digest(f.sourceData), second.id: digest(bytes)],
            destinations: [f.destinationRelative: .sha256(digest(f.destinationData)), secondRelative: .absent],
            modes: [f.session.id: .move, second.id: .copy])
        XCTAssertEqual(changes.count, 3)
        XCTAssertTrue(changes.prefix(2).allSatisfy { $0.data != nil })
        XCTAssertEqual(changes.last?.relative, f.session.recordRelativePath)
        let transaction = try f.transaction(changes)
        try await transaction.apply { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.source.path))
        XCTAssertEqual(try Data(contentsOf: secondSource), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.env.desktop.appendingPathComponent(secondRelative).path))
        try await transaction.rollback { }
        XCTAssertEqual(try Data(contentsOf: f.source), f.sourceData)
        XCTAssertEqual(try Data(contentsOf: f.destination), f.destinationData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.env.desktop.appendingPathComponent(secondRelative).path))
    }

    func testDifferentTranscriptCollisionCannotBeOverwritten() throws {
        let f = try fixture()
        let collision = try JSONSerialization.data(withJSONObject: ["sessionId": f.session.sessionID, "cliSessionId": UUID().uuidString])
        try SafeFiles.atomicWrite(collision, to: f.destination)
        XCTAssertThrowsError(try MigrationBuilder.changes(sessions: [f.session], target: f.target, environment: f.env,
            expectedDigests: [f.session.id: digest(f.sourceData)],
            destinations: [f.destinationRelative: .sha256(digest(collision))], modes: [:]))
    }

    func testSessionlessOrganizationFoldersDoNotBlockMigration() throws {
        let f = try fixture()
        let accountRoot = f.env.desktop.appendingPathComponent("claude-code-sessions/\(f.target.id)")
        let stray = accountRoot.appendingPathComponent(UUID().uuidString.lowercased() + "/scheduled-tasks.json")
        try SafeFiles.privateDirectory(stray.deletingLastPathComponent())
        try SafeFiles.atomicWrite(Data(#"{"scheduledTasks":[]}"#.utf8), to: stray)
        XCTAssertNoThrow(try f.changes())
        let other = accountRoot.appendingPathComponent(UUID().uuidString.lowercased() + "/local_\(UUID().uuidString.lowercased()).json")
        try SafeFiles.privateDirectory(other.deletingLastPathComponent())
        try SafeFiles.atomicWrite(Data("{}".utf8), to: other)
        XCTAssertThrowsError(try f.changes())
    }

    func testNewDestinationAndMissingTranscript() throws {
        let f = try fixture()
        try FileManager.default.removeItem(at: f.destination)
        let changes = try MigrationBuilder.changes(sessions: [f.session], target: f.target, environment: f.env,
            expectedDigests: [f.session.id: digest(f.sourceData)], destinations: [f.destinationRelative: .absent], modes: [:])
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes.first?.expectation, .absent)
        try FileManager.default.removeItem(at: f.transcript)
        XCTAssertThrowsError(try MigrationBuilder.changes(sessions: [f.session], target: f.target, environment: f.env,
            expectedDigests: [f.session.id: digest(f.sourceData)], destinations: [f.destinationRelative: .absent], modes: [:]))
    }
}
