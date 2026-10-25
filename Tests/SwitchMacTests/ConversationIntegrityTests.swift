import Foundation
import XCTest
import SwitchCore
import SwitchStorage
@testable import SwitchMac

final class ConversationIntegrityTests: XCTestCase {
    private let sourceID = "0a1b2c3d-1111-4aaa-8bbb-000000000001"
    private let sourceOrg = "0a1b2c3d-1111-4aaa-8bbb-000000000002"
    private let target = Account(id: "0a1b2c3d-1111-4aaa-8bbb-000000000003",
                                 organizationID: "0a1b2c3d-1111-4aaa-8bbb-000000000004")
    private struct Fixture {
        let environment: MacEnvironment
        let engine: SwitchEngine
        let sessions: [Conversation]
        let sourcePrefix: String
        let targetPrefix: String
        let queue: String
        let resource: String
        let originalRecords: [String: Data]
    }
    private func id(_ n: Int) -> String { String(format: "0a1b2c3d-1111-4aaa-8bbb-%012d", n) }
    private func write(_ data: Data, to file: URL) throws {
        try SafeFiles.privateDirectory(file.deletingLastPathComponent())
        try SafeFiles.atomicWrite(data, to: file)
    }
    private func fixture() throws -> Fixture {
        let home = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/integrity-fixtures/\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let env = MacEnvironment(home: home)
        let sourcePrefix = "claude-code-sessions/\(sourceID)/\(sourceOrg)"
        let targetPrefix = "claude-code-sessions/\(target.id)/\(target.organizationID!)"
        let cwd = home.appendingPathComponent("workspace"), extra = home.appendingPathComponent("attached-files")
        try SafeFiles.privateDirectory(cwd); try SafeFiles.privateDirectory(extra)
        var originals: [String: Data] = [:]
        for index in 0..<4 {
            let sid = id(10 + index), cli = id(20 + index)
            var record: [String: Any] = ["sessionId": sid, "cliSessionId": cli, "cwd": cwd.path,
                "title": "Fixture \(index)", "lastActivityAt": 1000, "isArchived": index == 3,
                "futureMetadata": ["opaque": ["array": [1, 2, 3], "text": "Complete original content"]],
                "sessionPermissionUpdates": [["type": "addDirectories", "directories": [extra.path], "destination": "session"]]]
            if index > 0 { record["spawnedFrom"] = ["sessionId": id(index == 2 ? 11 : 10), "sideSession": true, "taskId": "fixture-task-\(index)"] }
            let relative = sourcePrefix + "/" + sid + ".json"
            let data = try JSONSerialization.data(withJSONObject: record, options: .sortedKeys)
            try write(data, to: env.desktop.appendingPathComponent(relative)); originals[relative] = data
            let line = index == 0 ? #"{"type":"user","toolUseResult":{"agentId":"fixture-agent"}}"# : #"{"type":"user","message":{"content":"original history"}}"#
            try write(Data(line.utf8), to: env.projects.appendingPathComponent("fixture/\(cli).jsonl"))
        }
        try write(Data(#"{"type":"assistant","message":{"content":"complete child result"}}"#.utf8),
                  to: env.projects.appendingPathComponent("fixture/\(id(20))/subagents/agent-fixture-agent.jsonl"))
        try write(Data(#"{"toolUseId":"fixture-tool","parentAgentId":"fixture-parent","futureField":true}"#.utf8),
                  to: env.projects.appendingPathComponent("fixture/\(id(20))/subagents/agent-fixture-agent.meta.json"))
        let queue = "waiting-input/\(id(10)).json"
        let queued: [String: Any] = ["v": 1, "sessionId": id(10), "cleanShutdown": true, "futureQueueMetadata": ["retained": true],
            "entries": [["uuid": "fixture-message", "msg": ["uuid": "fixture-message", "type": "user",
                "message": ["role": "user", "content": "unabridged queued input"]]]]]
        try write(JSONSerialization.data(withJSONObject: queued),
                  to: env.desktop.appendingPathComponent(sourcePrefix + "/" + queue))
        let resource = "future-resource-store/\(id(10))/nested/.input.bin"
        try write(Data([0, 1, 255, 3, 4]), to: env.desktop.appendingPathComponent(sourcePrefix + "/" + resource))
        try SafeFiles.privateDirectory(env.desktop.appendingPathComponent(sourcePrefix + "/future-resource-store/\(id(10))/empty"))
        try write(Data(#"{"lastKnownAccountUuid":"0a1b2c3d-1111-4aaa-8bbb-000000000001"}"#.utf8), to: env.desktop.appendingPathComponent("config.json"))
        let sessions = try ConversationRecords.readScope(desktop: env.desktop, accountID: sourceID, organizationID: sourceOrg)
        return Fixture(environment: env, engine: SwitchEngine(environment: env, vault: CredentialVault(root: env.root.appendingPathComponent("vault"))),
            sessions: sessions, sourcePrefix: sourcePrefix, targetPrefix: targetPrefix, queue: queue, resource: resource, originalRecords: originals)
    }
    private func prepare(_ f: Fixture) async throws -> (OperationPlan, [MigrationChange], FileTransaction) {
        let root = try XCTUnwrap(f.sessions.first { $0.sessionID == id(10) })
        let plan = try await f.engine.prepare(kind: .migrate, target: target, sessions: [root])
        let changes = try MigrationBuilder.changes(sessions: XCTUnwrap(plan.transferSessions), target: target, environment: f.environment,
            expectedDigests: plan.sourceDigests, destinations: plan.destinationExpectations, resources: plan.resourceExpectations ?? [:])
        let transaction = try FileTransaction(parent: f.environment.root.appendingPathComponent("transactions"), live: f.environment.desktop, plan: plan)
        try MigrationBuilder.stage(changes, in: transaction)
        return (plan, changes, transaction)
    }

    func testPreviewIncludesWholeTreeAndOpaqueCompanionsWithoutWritingLiveData() async throws {
        let f = try fixture(), (plan, changes, _) = try await prepare(f)
        XCTAssertEqual(plan.transferSessions?.count, 4)
        XCTAssertEqual(Set(plan.conversationIDs), Set(f.sessions.map(\.id)))
        XCTAssertEqual(ConversationTree(try XCTUnwrap(plan.transferSessions)).childCount(of: f.sessions[0]), 2)
        XCTAssertTrue(changes.contains { $0.relative == f.targetPrefix + "/" + f.queue })
        XCTAssertTrue(changes.contains { $0.files?.contains { $0.path == f.targetPrefix + "/" + f.resource } == true })
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.environment.desktop.appendingPathComponent(f.targetPrefix).path))
        for (relative, original) in f.originalRecords { XCTAssertEqual(try SafeFiles.read(f.environment.desktop.appendingPathComponent(relative)), original) }
    }

    func testTransferPreservesRawRecordsResourcesAndSharedHistoryAndRecoversAfterRestart() async throws {
        try XCTSkipUnless(BuildAccess.allowsClaudeWrites, "Fixture writes require CLAUDE_WRITE_ENABLED")
        let f = try fixture(), (plan, _, transaction) = try await prepare(f)
        let retained = try ConversationResources.retained(sessions: XCTUnwrap(plan.transferSessions), environment: f.environment)
        try await transaction.apply(stopped: {}, verify: { try ConversationResources.validate(retained) })
        let transferred = try ConversationRecords.readScope(desktop: f.environment.desktop, accountID: target.id, organizationID: target.organizationID!)
        XCTAssertEqual(transferred.count, 4)
        let tree = ConversationTree(transferred)
        XCTAssertEqual(tree.roots.map(\.sessionID), [id(10)])
        XCTAssertEqual(tree.childCount(of: try XCTUnwrap(tree.roots.first)), 2)
        for (relative, bytes) in f.originalRecords {
            let destination = relative.replacingOccurrences(of: f.sourcePrefix, with: f.targetPrefix)
            XCTAssertEqual(try SafeFiles.read(f.environment.desktop.appendingPathComponent(destination)), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.environment.desktop.appendingPathComponent(relative).path))
        }
        XCTAssertEqual(try SafeFiles.read(f.environment.desktop.appendingPathComponent(f.targetPrefix + "/" + f.resource)), Data([0, 1, 255, 3, 4]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.environment.desktop.appendingPathComponent(f.sourcePrefix + "/" + f.resource).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.environment.desktop.appendingPathComponent(f.sourcePrefix + "/" + f.queue).path))
        try ConversationResources.validate(retained)
        let recovered = try FileTransaction(existing: transaction.root, live: f.environment.desktop)
        try await recovered.rollback { }
        for (relative, bytes) in f.originalRecords { XCTAssertEqual(try SafeFiles.read(f.environment.desktop.appendingPathComponent(relative)), bytes) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.environment.desktop.appendingPathComponent(f.sourcePrefix + "/" + f.queue).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.environment.desktop.appendingPathComponent(f.targetPrefix + "/" + f.resource).path))
    }

    func testEveryWriteBoundaryCanRollBackTheWholeGroup() async throws {
        try XCTSkipUnless(BuildAccess.allowsClaudeWrites, "Fixture writes require CLAUDE_WRITE_ENABLED")
        let probe = try fixture(), (_, _, preview) = try await prepare(probe)
        for failureAt in 0..<preview.journal.entries.count {
            let f = try fixture(), (_, _, transaction) = try await prepare(f)
            var step = 0
            do {
                try await transaction.apply {
                    defer { step += 1 }
                    if step == failureAt { throw SwitchError.changed }
                }
                XCTFail("Expected injected interruption")
            } catch { try await FileTransaction(existing: transaction.root, live: f.environment.desktop).rollback { } }
            for (relative, bytes) in f.originalRecords { XCTAssertEqual(try SafeFiles.read(f.environment.desktop.appendingPathComponent(relative)), bytes) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.environment.desktop.appendingPathComponent(f.sourcePrefix + "/" + f.queue).path))
            let targetRecords = try ConversationRecords.readScope(desktop: f.environment.desktop, accountID: target.id, organizationID: target.organizationID!)
            XCTAssertTrue(targetRecords.isEmpty)
        }
    }

    func testCorruptDestinationIsDetectedBeforeRemovingAnySource() async throws {
        try XCTSkipUnless(BuildAccess.allowsClaudeWrites, "Fixture writes require CLAUDE_WRITE_ENABLED")
        let f = try fixture(), (_, _, transaction) = try await prepare(f)
        let firstRemoval = try XCTUnwrap(transaction.journal.entries.firstIndex { $0.removalAfterInstall == true })
        var step = 0
        do {
            try await transaction.apply {
                if step == firstRemoval {
                    try SafeFiles.atomicWrite(Data("corrupted".utf8), to: f.environment.desktop.appendingPathComponent(f.targetPrefix + "/" + self.id(10) + ".json"))
                }
                step += 1
            }
            XCTFail("Destination verification must reject corruption")
        } catch {
            XCTAssertTrue(transaction.journal.entries.filter { $0.removalAfterInstall == true }.allSatisfy { !$0.started })
            try await transaction.rollback { }
        }
        for (relative, bytes) in f.originalRecords { XCTAssertEqual(try SafeFiles.read(f.environment.desktop.appendingPathComponent(relative)), bytes) }
    }

    func testNewChildAfterPreviewInvalidatesTheGroup() async throws {
        let f = try fixture(), (plan, _, _) = try await prepare(f)
        let extra: [String: Any] = ["sessionId": id(90), "cliSessionId": id(91), "cwd": "/fixture", "spawnedFrom": ["sessionId": id(10)]]
        try write(JSONSerialization.data(withJSONObject: extra), to: f.environment.desktop.appendingPathComponent(f.sourcePrefix + "/" + id(90) + ".json"))
        XCTAssertThrowsError(try MigrationBuilder.changes(sessions: XCTUnwrap(plan.transferSessions), target: target, environment: f.environment,
            expectedDigests: plan.sourceDigests, destinations: plan.destinationExpectations, resources: plan.resourceExpectations ?? [:]))
    }

    func testMissingNativeAgentOrFolderStopsBeforeTransfer() async throws {
        for missingAgent in [true, false] {
            let f = try fixture()
            let missing = missingAgent
                ? f.environment.projects.appendingPathComponent("fixture/\(id(20))/subagents/agent-fixture-agent.jsonl")
                : f.environment.home.appendingPathComponent("attached-files")
            try FileManager.default.removeItem(at: missing)
            do { _ = try await prepare(f); XCTFail("Missing dependency must stop the preview") } catch { }
            for (relative, bytes) in f.originalRecords { XCTAssertEqual(try SafeFiles.read(f.environment.desktop.appendingPathComponent(relative)), bytes) }
        }
    }

    func testConflictingResourceAndSymlinkAreNotSilentlySkipped() async throws {
        for symlink in [true, false] {
            let f = try fixture()
            if symlink {
                let link = f.environment.desktop.appendingPathComponent(f.sourcePrefix + "/future-resource-store/" + id(10) + "/link")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.environment.home)
            } else {
                try write(Data("conflict".utf8), to: f.environment.desktop.appendingPathComponent(f.targetPrefix + "/" + f.resource))
            }
            do { _ = try await prepare(f); XCTFail("Unsafe or conflicting resource must stop") } catch { }
            XCTAssertEqual(try SafeFiles.read(f.environment.desktop.appendingPathComponent(f.sourcePrefix + "/" + f.resource)), Data([0, 1, 255, 3, 4]))
        }
    }

    func testQueuedAttachmentMustExistAndMatchItsHash() async throws {
        let f = try fixture(), payload = Data("complete pending attachment".utf8), hash = digest(payload)
        let manifest = f.environment.desktop.appendingPathComponent(f.sourcePrefix + "/" + f.queue)
        var record = try JSONSerialization.jsonObject(with: SafeFiles.read(manifest)) as! [String: Any]
        record["futureAttachment"] = ["blob": hash]
        try SafeFiles.atomicWrite(JSONSerialization.data(withJSONObject: record), to: manifest)
        do { _ = try await prepare(f); XCTFail("Missing blob must stop") } catch { }
        let file = manifest.deletingPathExtension().appendingPathComponent(hash)
        try write(Data("wrong content".utf8), to: file)
        do { _ = try await prepare(f); XCTFail("Mismatched blob must stop") } catch { }
        try write(payload, to: file)
        let (_, changes, _) = try await prepare(f)
        XCTAssertTrue(changes.contains { $0.files?.contains { $0.sha256 == hash } == true })
    }

    func testSourceResourceMutationAfterStagingStopsBeforeSourceCleanup() async throws {
        try XCTSkipUnless(BuildAccess.allowsClaudeWrites)
        let f = try fixture(), (_, _, transaction) = try await prepare(f)
        try write(Data("newer original".utf8), to: f.environment.desktop.appendingPathComponent(f.sourcePrefix + "/" + f.resource))
        do { try await transaction.apply(stopped: {}); XCTFail("Source changed after staging") }
        catch { try await transaction.rollback(stopped: {}) }
        for (path, bytes) in f.originalRecords { XCTAssertEqual(try SafeFiles.read(f.environment.desktop.appendingPathComponent(path)), bytes) }
        XCTAssertEqual(try SafeFiles.read(f.environment.desktop.appendingPathComponent(f.sourcePrefix + "/" + f.resource)), Data("newer original".utf8))
    }

    func testDestinationOnlyQueueIsAConflict() async throws {
        let f = try fixture()
        try write(Data("old pending work".utf8), to: f.environment.desktop.appendingPathComponent(f.targetPrefix + "/waiting-input/" + id(11) + ".json"))
        do { _ = try await prepare(f); XCTFail("A stale target queue must not run alongside the transferred group") } catch { }
    }

    func testRecoveryCapacityIsCheckedBeforeAnyRename() async throws {
        try XCTSkipUnless(BuildAccess.allowsClaudeWrites)
        let f = try fixture(), (_, _, transaction) = try await prepare(f)
        let large = f.environment.desktop.appendingPathComponent("Cookies")
        try write(Data(), to: large)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 65 * 1024 * 1024); try handle.close()
        try transaction.stage(relative: "Cookies", data: Data())
        do { try await transaction.apply(stopped: {}); XCTFail("Oversized recovery must stop before writes") } catch { }
        XCTAssertTrue(transaction.journal.entries.allSatisfy { !$0.started })
        for (path, bytes) in f.originalRecords { XCTAssertEqual(try SafeFiles.read(f.environment.desktop.appendingPathComponent(path)), bytes) }
    }

    func testReturningConversationUnionsAttachmentsWithoutErasingHistoricalPaths() async throws {
        let f = try fixture()
        let folder = "future-resource-store/" + id(10)
        try write(Data("historic attachment".utf8), to: f.environment.desktop.appendingPathComponent(f.targetPrefix + "/" + folder + "/older.txt"))
        let (_, changes, _) = try await prepare(f)
        let files = try XCTUnwrap(changes.first { $0.relative == f.targetPrefix + "/" + folder }?.files)
        XCTAssertTrue(files.contains { $0.path.hasSuffix("older.txt") })
        XCTAssertTrue(files.contains { $0.path.hasSuffix(".input.bin") })
    }

    func testPersistentBrowserCredentialsRequireClaudeReauthorization() async throws {
        let f = try fixture(), config = f.environment.desktop.appendingPathComponent("config.json")
        var record = try JSONSerialization.jsonObject(with: SafeFiles.read(config)) as! [String: Any]
        record["launchPreviewStorage"] = "session"
        try SafeFiles.atomicWrite(JSONSerialization.data(withJSONObject: record), to: config)
        try write(Data("synthetic website credentials".utf8), to: f.environment.desktop.appendingPathComponent("Partitions/launch-preview-session-fixture/Cookies"))
        do { _ = try await prepare(f); XCTFail("Persistent browser authority must not follow a stable session ID") } catch { }
        record["launchPreviewStorage"] = "none"
        try SafeFiles.atomicWrite(JSONSerialization.data(withJSONObject: record), to: config)
        _ = try await prepare(f)
    }
}
