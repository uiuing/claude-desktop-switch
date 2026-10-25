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
        func changes(prepared: [MigrationChange] = []) throws -> [MigrationChange] {
            try MigrationBuilder.changes(sessions: [session], target: target, environment: env,
                expectedDigests: [session.id: digest(sourceData)],
                destinations: [destinationRelative: .sha256(digest(destinationData))],
                preparedTransfers: Dictionary(uniqueKeysWithValues: prepared.compactMap { change in
                    change.data.map { (change.relative, $0) }
                }))
        }
        func transaction(_ changes: [MigrationChange]) throws -> FileTransaction {
            let plan = OperationPlan(kind: .migrate, sourceAccountID: session.accountID, targetAccountID: target.id,
                                     configDigest: "fixture", steps: [])
            let transaction = try FileTransaction(parent: env.root.appendingPathComponent("transactions"), live: env.desktop, plan: plan)
            try MigrationBuilder.stage(changes, in: transaction)
            return transaction
        }
    }
    private func fixture(permissionMode: String? = "bypassPermissions", sourceFields: [String: Any] = [:],
                         targetFields: [String: Any] = [:]) throws -> Fixture {
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
        var record: [String: Any] = ["sessionId": sid, "cliSessionId": cli, "cwd": home.appendingPathComponent("workspace").path,
                                    "title": "Latest", "remoteControl": true, "lastActivityAt": 200]
        try SafeFiles.privateDirectory(home.appendingPathComponent("workspace"))
        if let permissionMode { record["permissionMode"] = permissionMode }
        record.merge(sourceFields) { _, new in new }
        let sourceData = try JSONSerialization.data(withJSONObject: record, options: .sortedKeys)
        var targetRecord: [String: Any] = ["sessionId": sid, "cliSessionId": cli,
            "cwd": "/old/project", "title": "Old", "permissionMode": "plan", "lastActivityAt": 100]
        targetRecord.merge(targetFields) { _, new in new }
        let destinationData = try JSONSerialization.data(withJSONObject: targetRecord, options: .sortedKeys)
        for (url, data) in [(source, sourceData), (destination, destinationData), (transcript, Data(#"{"type":"user","message":{"content":"shared transcript"}}"#.utf8))] {
            try SafeFiles.privateDirectory(url.deletingLastPathComponent()); try SafeFiles.atomicWrite(data, to: url)
        }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: source.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: destination.path)
        try SafeFiles.atomicWrite(JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": owner]), to: env.desktop.appendingPathComponent("config.json"))
        return Fixture(env: env, session: session, target: target, source: source, destination: destination,
                       transcript: transcript, sourceData: sourceData, destinationData: destinationData)
    }

    func testPreviewCapturesExistingTarget() async throws {
        let f = try fixture(), vault = CredentialVault(root: f.env.root.appendingPathComponent("vault"))
        let engine = SwitchEngine(environment: f.env, vault: vault)
        let plan = try await engine.prepare(kind: .migrate, target: f.target, sessions: [f.session])
        XCTAssertEqual(plan.destinationExpectations[f.destinationRelative], .sha256(digest(f.destinationData)))
        XCTAssertEqual(try Data(contentsOf: f.source), f.sourceData)
        XCTAssertEqual(try Data(contentsOf: f.destination), f.destinationData)
    }

    func testSwitchPreviewCanDeselectAllAndRevalidateSelectedRecords() async throws {
        let f = try fixture(), vault = CredentialVault(root: f.env.root.appendingPathComponent("vault"))
        let engine = SwitchEngine(environment: f.env, vault: vault)
        let selected = try await engine.prepare(kind: .switchAccount, target: f.target, sessions: [f.session])
        XCTAssertEqual(selected.conversationIDs, [f.session.id])
        XCTAssertEqual(selected.sourceDigests[f.session.id], digest(f.sourceData))
        let empty = try await engine.prepare(kind: .switchAccount, target: f.target)
        XCTAssertTrue(empty.conversationIDs.isEmpty)
        XCTAssertTrue(empty.sourceDigests.isEmpty)
        XCTAssertTrue(empty.destinationExpectations.isEmpty)
        XCTAssertFalse(empty.steps.contains(L10n.tr("Bring selected conversations and their subtasks to this account")))
        let reselected = try await engine.prepare(kind: .switchAccount, target: f.target, sessions: [f.session])
        XCTAssertEqual(reselected.destinationExpectations[f.destinationRelative], .sha256(digest(f.destinationData)))
        XCTAssertEqual(try Data(contentsOf: f.source), f.sourceData)
        XCTAssertEqual(try Data(contentsOf: f.destination), f.destinationData)
    }

    func testTransferReplacesSameSessionAndKeepsSharedTranscript() async throws {
        try XCTSkipUnless(BuildAccess.allowsClaudeWrites, "Run isolated fixture tests with CLAUDE_WRITE_ENABLED")
        let f = try fixture(), changes = try f.changes(), transaction = try f.transaction(changes)
        XCTAssertEqual(changes.first?.relative, f.destinationRelative)
        try await transaction.apply { }
        try transaction.commit()
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.source.path))
        let updated = try SafeFiles.json(f.destination)
        XCTAssertEqual(updated["title"].string, "Latest")
        XCTAssertEqual(updated["permissionMode"].string, "bypassPermissions")
        XCTAssertEqual(updated["remoteControl"].bool, true)
        XCTAssertEqual(try Data(contentsOf: f.transcript), Data(#"{"type":"user","message":{"content":"shared transcript"}}"#.utf8))
        XCTAssertEqual(try Data(contentsOf: transaction.root.appendingPathComponent("originals/" + f.destinationRelative)), f.destinationData)

    }

    func testFollowedTransferKeepsOriginalPermissionMode() async throws {
        try XCTSkipUnless(BuildAccess.allowsClaudeWrites, "Run isolated fixture tests with CLAUDE_WRITE_ENABLED")
        let permissionModes: [String?] = ["auto", "default", "acceptEdits", "plan", "bypassPermissions", "dontAsk", nil]
        for permissionMode in permissionModes {
            let f = try fixture(permissionMode: permissionMode)
            let rule = FollowRule(conversationID: f.session.id, sessionID: f.session.sessionID)
            let sessions = SessionLibrary.followedSessions([f.session], rules: [rule],
                activeAccountID: f.session.accountID, targetAccountID: f.target.id)
            let engine = SwitchEngine(environment: f.env, vault: CredentialVault(root: f.env.root.appendingPathComponent("vault")))
            let plan = try await engine.prepare(kind: .switchAccount, target: f.target, sessions: sessions)
            let changes = try MigrationBuilder.changes(sessions: sessions, target: f.target, environment: f.env,
                expectedDigests: plan.sourceDigests, destinations: plan.destinationExpectations)
            let transaction = try f.transaction(changes)
            try await transaction.apply { }
            let updated = try SafeFiles.json(f.destination)
            XCTAssertEqual(updated.object?["permissionMode"], permissionMode.map { JSONValue.string($0) })
            XCTAssertEqual(updated["remoteControl"].bool, true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.source.path))
            try await transaction.rollback { }
            XCTAssertEqual(try Data(contentsOf: f.source), f.sourceData)
            XCTAssertEqual(try Data(contentsOf: f.destination), f.destinationData)
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

    func testTransferKeepsWorktreePreferencesAndHistory() async throws {
        try XCTSkipUnless(BuildAccess.allowsClaudeWrites, "Run isolated fixture tests with CLAUDE_WRITE_ENABLED")
        let metadata: [String: Any] = [
            "worktreePath": "/fixture/worktrees/feature", "worktreeName": "feature", "branch": "feature", "sourceBranch": "main",
            "isStarred": true, "color": "blue", "effortInherited": true, "autoArchiveOnPrClose": false,
            "sessionSettings": ["outputStyle": "concise", "ultracode": true, "futureOption": "fixture"], "autoChosenInApp": true,
            "priorCliSessionIds": ["0a1b2c3d-1111-4aaa-8bbb-000000000099"],
            "prs": [["number": 17, "branch": "feature"]], "futureState": ["nested": ["enabled": true]]
        ]
        let f = try fixture(permissionMode: "auto", sourceFields: metadata)
        let transaction = try f.transaction(f.changes())
        try await transaction.apply { }
        let source = try JSONDecoder().decode(JSONValue.self, from: f.sourceData)
        let target = try SafeFiles.json(f.destination)
        for key in metadata.keys { XCTAssertEqual(target[key], source[key], key) }
        XCTAssertEqual(target["permissionMode"].string, "auto")
        XCTAssertEqual(try Data(contentsOf: f.transcript), Data(#"{"type":"user","message":{"content":"shared transcript"}}"#.utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.source.path))
        try await transaction.rollback { }
        XCTAssertEqual(try Data(contentsOf: f.source), f.sourceData)
        XCTAssertEqual(try Data(contentsOf: f.destination), f.destinationData)

    }

    func testSelectedSourceCanReplaceRegardlessOfActivityTime() async throws {
        for date: Any in [300, 200, NSNull(), "invalid"] {
            let f = try fixture(targetFields: ["lastActivityAt": date])
            for kind in [OperationKind.switchAccount, .migrate] {
                let engine = SwitchEngine(environment: f.env, vault: CredentialVault(root: f.env.root.appendingPathComponent("vault")))
                let plan = try await engine.prepare(kind: kind, target: f.target, sessions: [f.session])
                XCTAssertEqual(plan.conversationIDs, [f.session.id])
            }
            XCTAssertNoThrow(try f.changes())
            XCTAssertEqual(try Data(contentsOf: f.source), f.sourceData)
            XCTAssertEqual(try Data(contentsOf: f.destination), f.destinationData)
        }
    }

    func testNewSourceOrTargetFieldsDoNotBlockTransfer() throws {
        for source in [true, false] {
            let fields: [String: Any] = ["futureSetting": true]
            let f = try fixture(sourceFields: source ? fields : [:], targetFields: source ? [:] : fields)
            let changes = try f.changes()
            let transferred = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(changes.first?.data))
            XCTAssertEqual(transferred["futureSetting"].bool, source ? true : nil)
            XCTAssertEqual(try Data(contentsOf: f.source), f.sourceData)
            XCTAssertEqual(try Data(contentsOf: f.destination), f.destinationData)
        }
    }

    func testFileModificationTimeDoesNotOverrideTheSelectedSource() throws {
        let f = try fixture()
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 300)], ofItemAtPath: f.destination.path)
        XCTAssertNoThrow(try f.changes())
        XCTAssertEqual(try Data(contentsOf: f.source), f.sourceData)
        XCTAssertEqual(try Data(contentsOf: f.destination), f.destinationData)
    }

    func testModeOnlyEditWithUnchangedActivityFollowsAndRollsBack() async throws {
        try XCTSkipUnless(BuildAccess.allowsClaudeWrites, "Run isolated fixture tests with CLAUDE_WRITE_ENABLED")
        let f = try fixture(permissionMode: "auto", sourceFields: ["autoChosenInApp": true],
                            targetFields: ["lastActivityAt": 200, "permissionMode": "default"])
        var targetSession = f.session
        targetSession.accountID = f.target.id; targetSession.organizationID = f.target.organizationID!
        targetSession.id = f.target.id + "/" + f.target.organizationID! + "/code/" + f.session.sessionID
        let rule = FollowRule(conversationID: f.session.id, sessionID: f.session.sessionID)
        let selected = SessionLibrary.followedSessions([f.session, targetSession], rules: [rule],
            activeAccountID: f.session.accountID, targetAccountID: f.target.id)
        XCTAssertEqual(selected.map(\.id), [f.session.id])
        let changes = try MigrationBuilder.changes(sessions: selected, target: f.target, environment: f.env,
            expectedDigests: [f.session.id: digest(f.sourceData)], destinations: [f.destinationRelative: .sha256(digest(f.destinationData))])
        let transaction = try f.transaction(changes)
        try await transaction.apply { }
        let transferred = try SafeFiles.json(f.destination)
        XCTAssertEqual(transferred["permissionMode"].string, "auto")
        XCTAssertEqual(transferred["autoChosenInApp"].bool, true)
        try await transaction.rollback { }
        XCTAssertEqual(try Data(contentsOf: f.source), f.sourceData)
        XCTAssertEqual(try Data(contentsOf: f.destination), f.destinationData)
    }

    func testFallbackWithAnExistingTargetProducesNoWritesOrRemovals() throws {
        let f = try fixture()
        var targetSession = f.session
        targetSession.accountID = f.target.id; targetSession.id = "target-copy"
        let rule = FollowRule(conversationID: f.session.id, sessionID: f.session.sessionID)
        let selected = SessionLibrary.followedSessions([f.session, targetSession], rules: [rule],
            activeAccountID: "0a1b2c3d-1111-4aaa-8bbb-000000000099", targetAccountID: f.target.id)
        let changes = try MigrationBuilder.changes(sessions: selected, target: f.target, environment: f.env,
            expectedDigests: [:], destinations: [:])
        XCTAssertTrue(changes.isEmpty)

        XCTAssertEqual(try Data(contentsOf: f.source), f.sourceData)
        XCTAssertEqual(try Data(contentsOf: f.destination), f.destinationData)
    }

    func testInvalidResumeIdentityOrWorkingDirectoryStillBlocksTransfer() throws {
        for fields: [String: Any] in [["sessionId": "different"], ["cliSessionId": "different"], ["cwd": true]] {
            let f = try fixture(sourceFields: fields)
            XCTAssertThrowsError(try f.changes())
            XCTAssertEqual(try Data(contentsOf: f.source), f.sourceData)
            XCTAssertEqual(try Data(contentsOf: f.destination), f.destinationData)
        }
    }

    func testTransferPreservesNonCredentialMetadataAndRollbackRestoresOriginals() async throws {
        try XCTSkipUnless(BuildAccess.allowsClaudeWrites, "Run isolated fixture tests with CLAUDE_WRITE_ENABLED")
        let f = try fixture(permissionMode: "auto", sourceFields: [
            "movedToCloud": ["cloudSessionId": "cloud-fixture"], "spaceId": "space-fixture", "scheduledTaskId": "routine-fixture",
            "pendingFirstStart": ["options": ["remoteControlAtStart": true, "useWorktree": true]],
            "sessionSettings": ["outputStyle": "concise"], "cuSelectedDisplayId": 7
        ])
        let transaction = try f.transaction(f.changes())
        try await transaction.apply { }
        let transferred = try SafeFiles.json(f.destination)
        for key in ["movedToCloud", "spaceId", "scheduledTaskId"] { XCTAssertNotNil(transferred.object?[key]) }
        XCTAssertEqual(transferred["pendingFirstStart"]["options"]["remoteControlAtStart"].bool, true)
        XCTAssertEqual(transferred["pendingFirstStart"]["options"]["useWorktree"].bool, true)
        XCTAssertEqual(transferred["permissionMode"].string, "auto")
        XCTAssertEqual(transferred["sessionSettings"]["outputStyle"].string, "concise")
        XCTAssertEqual(transferred["cuSelectedDisplayId"].number, 7)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.source.path))
        try await transaction.rollback { }
        XCTAssertEqual(try Data(contentsOf: f.source), f.sourceData)
        XCTAssertEqual(try Data(contentsOf: f.destination), f.destinationData)

    }

    func testTargetChangesAfterPreviewAreRejected() throws {
        let f = try fixture()
        try SafeFiles.atomicWrite(Data("changed target".utf8), to: f.destination)
        XCTAssertThrowsError(try f.changes())
        XCTAssertEqual(try Data(contentsOf: f.source), f.sourceData)
    }

    func testQuitOnlyConnectionChangesKeepThePreparedTransfer() throws {
        let f = try fixture(), prepared = try f.changes()
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: f.sourceData) as? [String: Any])
        record["remoteControlLiveAtUpdateQuit"] = true
        record["armedWorkAtQuit"] = ["fixture": true]
        let stopped = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .prettyPrinted])
        try SafeFiles.atomicWrite(stopped, to: f.source)
        XCTAssertThrowsError(try f.changes())
        let final = try f.changes(prepared: prepared)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(final.first?.data))["armedWorkAtQuit"]["fixture"].bool, true)
        XCTAssertEqual(final.last?.expectation, .sha256(digest(stopped)))
    }

    func testQuitRevalidationRejectsChangesToIdentityAndWorkspace() throws {
        for fields: [String: Any] in [
            ["cwd": "/fixture/other"], ["worktreePath": "/fixture/new-worktree"],
            ["sessionId": UUID().uuidString], ["cliSessionId": UUID().uuidString],
            ["forkedFromSessionId": UUID().uuidString], ["lineageDetached": true]
        ] {
            let f = try fixture(), prepared = try f.changes()
            var record = try XCTUnwrap(JSONSerialization.jsonObject(with: f.sourceData) as? [String: Any])
            record.merge(fields) { _, new in new }
            let changed = try JSONSerialization.data(withJSONObject: record, options: .sortedKeys)
            try SafeFiles.atomicWrite(changed, to: f.source)
            XCTAssertThrowsError(try f.changes(prepared: prepared))
            XCTAssertEqual(try Data(contentsOf: f.source), changed)
            XCTAssertEqual(try Data(contentsOf: f.destination), f.destinationData)
        }
    }

    func testQuitRevalidationStillRejectsTargetChanges() throws {
        let f = try fixture(), prepared = try f.changes()
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: f.destinationData) as? [String: Any])
        record["remoteControlLiveAtUpdateQuit"] = true
        let changed = try JSONSerialization.data(withJSONObject: record, options: .sortedKeys)
        try SafeFiles.atomicWrite(changed, to: f.destination)
        XCTAssertThrowsError(try f.changes(prepared: prepared))
        XCTAssertEqual(try Data(contentsOf: f.source), f.sourceData)
        XCTAssertEqual(try Data(contentsOf: f.destination), changed)
    }

    func testQuitRevalidatedTransferRollsBackToTheStoppedSource() async throws {
        try XCTSkipUnless(BuildAccess.allowsClaudeWrites, "Run isolated fixture tests with CLAUDE_WRITE_ENABLED")
        let f = try fixture(), prepared = try f.changes()
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: f.sourceData) as? [String: Any])
        record["armedWorkAtQuit"] = ["fixture": true]
        let stopped = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .prettyPrinted])
        try SafeFiles.atomicWrite(stopped, to: f.source)
        let transaction = try f.transaction(f.changes(prepared: prepared))
        try await transaction.apply { }
        XCTAssertEqual(try SafeFiles.json(f.destination)["armedWorkAtQuit"]["fixture"].bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.source.path))
        XCTAssertEqual(try Data(contentsOf: f.transcript), Data(#"{"type":"user","message":{"content":"shared transcript"}}"#.utf8))
        try await transaction.rollback { }
        XCTAssertEqual(try Data(contentsOf: f.source), stopped)
        XCTAssertEqual(try Data(contentsOf: f.destination), f.destinationData)

    }

    func testSourceChangesAfterQuitRevalidationStillBlockRemoval() async throws {
        try XCTSkipUnless(BuildAccess.allowsClaudeWrites, "Run isolated fixture tests with CLAUDE_WRITE_ENABLED")
        let f = try fixture(), prepared = try f.changes()
        let transaction = try f.transaction(f.changes(prepared: prepared))
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: f.sourceData) as? [String: Any])
        record["armedWorkAtQuit"] = ["fixture": true]
        let newer = try JSONSerialization.data(withJSONObject: record, options: .sortedKeys)
        try SafeFiles.atomicWrite(newer, to: f.source)
        do { try await transaction.apply { }; XCTFail("The revalidated source digest must prevent removal") }
        catch { try await transaction.rollback { } }
        XCTAssertEqual(try Data(contentsOf: f.source), newer)
        XCTAssertEqual(try Data(contentsOf: f.destination), f.destinationData)
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

    func testBatchInstallsAllTargetsBeforeRemovingEverySource() async throws {
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
            destinations: [f.destinationRelative: .sha256(digest(f.destinationData)), secondRelative: .absent])
        XCTAssertEqual(changes.count, 4)
        XCTAssertTrue(changes.prefix(2).allSatisfy { $0.data != nil })
        XCTAssertEqual(Set(changes.suffix(2).map(\.relative)), [f.session.recordRelativePath, second.recordRelativePath])
        let transaction = try f.transaction(changes)
        try await transaction.apply { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondSource.path))
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
            destinations: [f.destinationRelative: .sha256(digest(collision))]))
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

    func testGuessedOrganizationMustMatchWhereTheTargetsSessionsAre() throws {
        let f = try fixture()
        try FileManager.default.removeItem(at: f.destination)
        let elsewhere = f.env.desktop.appendingPathComponent(
            "claude-code-sessions/\(f.target.id)/\(UUID().uuidString.lowercased())/\(UUID().uuidString.lowercased()).json")
        try SafeFiles.privateDirectory(elsewhere.deletingLastPathComponent())
        try SafeFiles.atomicWrite(Data("{}".utf8), to: elsewhere)
        func changes(_ target: Account) throws -> [MigrationChange] {
            try MigrationBuilder.changes(sessions: [f.session], target: target, environment: f.env,
                expectedDigests: [f.session.id: digest(f.sourceData)], destinations: [f.destinationRelative: .absent])
        }
        XCTAssertThrowsError(try changes(f.target))
        var confirmed = f.target
        confirmed.organizationVerifiedAt = Date()
        XCTAssertNoThrow(try changes(confirmed))
    }

    func testNewDestinationAndMissingTranscript() throws {
        let f = try fixture()
        try FileManager.default.removeItem(at: f.destination)
        let changes = try MigrationBuilder.changes(sessions: [f.session], target: f.target, environment: f.env,
            expectedDigests: [f.session.id: digest(f.sourceData)], destinations: [f.destinationRelative: .absent])
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes.first?.expectation, .absent)
        let updated = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(changes.first?.data))
        XCTAssertEqual(updated["permissionMode"].string, "bypassPermissions")
        try FileManager.default.removeItem(at: f.transcript)
        XCTAssertThrowsError(try MigrationBuilder.changes(sessions: [f.session], target: f.target, environment: f.env,
            expectedDigests: [f.session.id: digest(f.sourceData)], destinations: [f.destinationRelative: .absent]))
    }

    func testNewlySignedInTargetWithoutSessionDirectoryTransfersOnlyAfterConfirmation() async throws {
        try XCTSkipUnless(BuildAccess.allowsClaudeWrites, "Run isolated fixture tests with CLAUDE_WRITE_ENABLED")
        let f = try fixture()
        let targetRoot = f.env.desktop.appendingPathComponent("claude-code-sessions/\(f.target.id)")
        try FileManager.default.removeItem(at: targetRoot)
        let config = f.env.desktop.appendingPathComponent("config.json")
        let signedIn = try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": f.target.id])
        try SafeFiles.atomicWrite(signedIn, to: config)
        var target = f.target; target.organizationVerifiedAt = Date()
        let engine = SwitchEngine(environment: f.env, vault: CredentialVault(root: f.env.root.appendingPathComponent("vault")))
        let plan = try await engine.prepare(kind: .migrate, target: target, sessions: [f.session])
        XCTAssertEqual(plan.sourceAccountID, target.id)
        XCTAssertEqual(plan.destinationExpectations[f.destinationRelative], .absent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetRoot.path))
        XCTAssertEqual(try Data(contentsOf: f.source), f.sourceData)

        let changes = try MigrationBuilder.changes(sessions: [f.session], target: target, environment: f.env,
            expectedDigests: plan.sourceDigests, destinations: plan.destinationExpectations)
        let transaction = try f.transaction(changes)
        try await transaction.apply { }
        XCTAssertEqual(try SafeFiles.json(f.destination)["cliSessionId"].string, f.session.cliSessionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.source.path))
        XCTAssertEqual(try Data(contentsOf: config), signedIn)
        XCTAssertEqual(try Data(contentsOf: f.transcript), Data(#"{"type":"user","message":{"content":"shared transcript"}}"#.utf8))
        try await transaction.rollback { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination.path))
        XCTAssertEqual(try Data(contentsOf: f.source), f.sourceData)

    }
}
