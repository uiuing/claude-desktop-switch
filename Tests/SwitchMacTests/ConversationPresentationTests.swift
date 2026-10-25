import Foundation
import XCTest
import SwitchCore
import SwitchStorage
@testable import SwitchMac

final class ConversationPresentationTests: XCTestCase {
    private let sid = "0a1b2c3d-1111-4aaa-8bbb-000000000010"
    private let other = "0a1b2c3d-1111-4aaa-8bbb-000000000011"
    private let prefix = Data("_https://claude.ai\0".utf8)
    private func key(_ name: String) -> Data { prefix + Data([1]) + Data(name.utf8) }
    private func value(_ object: Any) throws -> Data {
        ConversationPresentation.encode(String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }
    private func files(_ values: [Data: Data]) throws -> [ArchiveFile] {
        try LevelDBSnapshot.files(values).map { ArchiveFile(path: ConversationPresentation.prefix + $0.key, data: $0.value, sha256: digest($0.value)) }
    }
    private func snapshot(_ values: [Data: Data]) throws -> LoginSnapshot {
        try LoginSnapshot(accountID: other, version: "3.0.0", createdAt: Date(), auth: [:], files: files(values), directories: ["Local Storage", "Local Storage/leveldb"])
    }
    private func read(_ snapshot: LoginSnapshot) throws -> [Data: Data] {
        try LevelDBSnapshot.read(Dictionary(uniqueKeysWithValues: snapshot.files.map { (String($0.path.dropFirst(ConversationPresentation.prefix.count)), $0.data) }))
    }
    func testOrdinaryRenderTokensAndDraftContentSurvivePresentationTransfer() throws {
        let state: [String: Any] = ["currentSessionId": sid, "renderToken": "ordinary-render-id",
            "draft": ["text": "Original draft", "parameters": ["token": "historical value", "password": "example"]],
            "auth": ["accessToken": "synthetic-source-credential"]]
        let merged = try ConversationPresentation.mergeStore(["state": state], into: [:], ids: [sid])
        let result = try XCTUnwrap(merged["state"] as? [String: Any])
        XCTAssertEqual(result["renderToken"] as? String, "ordinary-render-id")
        XCTAssertEqual(result["draft"] as? NSDictionary, state["draft"] as? NSDictionary)
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: merged), as: UTF8.self).contains("synthetic-source-credential"))
    }
    func testMergePreservesUnknownScopedFieldsAndTargetCredentialsWithoutSourceCredentials() throws {
        let pane = key(ConversationPresentation.pane), auth = key("synthetic-login")
        let original: [String: Any] = ["version": 6, "state": ["currentSessionId": sid,
            "fileTabs": [["path": "/fixture/output.html", "futureField": [1, 2]]],
            "futureArtifacts": [other: ["unknownPayload": "not a session map"]],
            "futureBySession": [sid: ["newSetting": true, "accessToken": "synthetic-source-secret"]],
            "tileLayoutBySession": [sid: ["root": "selected"], "not-selected": ["root": "unrelated"]]]]
        let target: [String: Any] = ["version": 6, "state": ["futureBySession": [other: ["targetOnly": true]],
            "tileLayoutBySession": [other: ["root": "existing"]]]]
        let source = try files([pane: value(original), auth: Data("synthetic-source-login".utf8)])
        let targetAuth = Data([0, 1, 255, 2]), input = try snapshot([pane: value(target), auth: targetAuth])
        let result = try read(ConversationPresentation.merge(source: source, target: input, ids: [sid]))
        XCTAssertEqual(result[auth], targetAuth)
        let json = try JSONSerialization.jsonObject(with: Data(ConversationPresentation.decode(XCTUnwrap(result[pane])).utf8)) as! [String: Any]
        let state = json["state"] as! [String: Any], future = state["futureBySession"] as! [String: [String: Any]]
        XCTAssertEqual(future[sid]?["newSetting"] as? Bool, true)
        XCTAssertNil(future[sid]?["accessToken"])
        XCTAssertEqual(future[other]?["targetOnly"] as? Bool, true)
        XCTAssertEqual((state["fileTabs"] as? [[String: Any]])?.first?["path"] as? String, "/fixture/output.html")
        XCTAssertEqual((state["futureArtifacts"] as? [String: [String: String]])?[other]?["unknownPayload"], "not a session map")
    }
    func testInactiveStoreMergesOnlySelectedMembersAndRefusesVersionConflict() throws {
        let source: [String: Any] = ["version": 6, "state": ["currentSessionId": other,
            "fileTabs": ["unrelated"], "futureNested": ["items": [sid: ["opaque": "retained"], other: ["opaque": "source-other"]]]]]
        let target: [String: Any] = ["version": 6, "state": ["currentSessionId": other, "fileTabs": ["target"],
            "futureNested": ["items": [other: ["opaque": "target-other"]]]]]
        let merged = try ConversationPresentation.mergeStore(source, into: target, ids: [sid])
        let state = merged["state"] as! [String: Any]
        XCTAssertEqual(state["fileTabs"] as? [String], ["target"])
        let items = (state["futureNested"] as! [String: Any])["items"] as! [String: [String: String]]
        XCTAssertEqual(items[sid]?["opaque"], "retained"); XCTAssertEqual(items[other]?["opaque"], "target-other")
        XCTAssertThrowsError(try ConversationPresentation.mergeStore(source, into: ["version": 99], ids: [sid]))
    }
    func testUnknownVersionWithoutConflictingTargetAndUnicodeArePreserved() throws {
        let source: [String: Any] = ["version": 999, "state": ["future": [sid: ["name": "\u{6d4b}\u{8bd5}\u{1f680}"]]]]
        let result = try ConversationPresentation.mergeStore(source, into: [:], ids: [sid])
        XCTAssertTrue(NSDictionary(dictionary: result).isEqual(to: source))
        XCTAssertEqual(try ConversationPresentation.decode(ConversationPresentation.encode("\u{1f680}")), "\u{1f680}")
    }
    func testPresentationSwapAndRestartRecoveryPreserveEveryOriginalByte() async throws {
        try XCTSkipUnless(BuildAccess.allowsClaudeWrites)
        let home = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/presentation-fixtures/\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = MacEnvironment(home: home), pane = key(ConversationPresentation.pane), auth = key("synthetic-login")
        let sourceFiles = try files([pane: value(["version": 6, "state": ["currentSessionId": sid, "future": ["new": true]]]), auth: Data([7])])
        for file in sourceFiles {
            let url = env.desktop.appendingPathComponent(file.path)
            try SafeFiles.privateDirectory(url.deletingLastPathComponent()); try SafeFiles.atomicWrite(file.data, to: url)
        }
        let original = try ConversationResources.fingerprint(env.desktop.appendingPathComponent("Local Storage"))
        let result = try ConversationPresentation.merge(source: sourceFiles, target: snapshot([auth: Data([9])]), ids: [sid])
        let plan = OperationPlan(kind: .switchAccount, sourceAccountID: sid, targetAccountID: other, configDigest: "fixture", steps: [], conversationIDs: [], warnings: [])
        let transaction = try FileTransaction(parent: home.appendingPathComponent("transactions"), live: env.desktop, plan: plan)
        try transaction.stageContainer("Local Storage", files: result.files, directories: result.directories)
        try await transaction.apply(stopped: {})
        XCTAssertNotEqual(try ConversationResources.fingerprint(env.desktop.appendingPathComponent("Local Storage")), original)
        try await FileTransaction(existing: transaction.root, live: env.desktop).rollback(stopped: {})
        XCTAssertEqual(try ConversationResources.fingerprint(env.desktop.appendingPathComponent("Local Storage")), original)
    }

    func testSeparateTransferRetainsPresentationUntilALaterAccountSwitch() async throws {
        try XCTSkipUnless(BuildAccess.allowsClaudeWrites)
        let home = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/presentation-fixtures/\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = MacEnvironment(home: home), org = "0a1b2c3d-1111-4aaa-8bbb-000000000012"
        let target = Account(id: other, organizationID: org)
        var session = Conversation(id: "fixture", sessionID: sid, accountID: sid, organizationID: org, title: "Fixture", kind: .code,
            modifiedAt: Date(), recordRelativePath: "unused", cliSessionID: sid)
        let pane = key(ConversationPresentation.pane), source = try files([pane: value(["version": 6,
            "state": ["currentSessionId": sid, "futureLayout": ["opaque": "preserved"], "fileTabs": [["path": "/fixture/report.html"]]]]),
            key("synthetic-login"): Data("source-credential".utf8)])
        let path = try ConversationPresentation.relative(session, target: target)
        let changes = try ConversationPresentation.changes(sessions: [session], sources: [sid: [source]], target: target,
            environment: env, expectations: ["presentation:" + path: .absent])
        XCTAssertEqual(changes.count, 1)
        let plan = OperationPlan(kind: .migrate, sourceAccountID: sid, targetAccountID: other, configDigest: "fixture", steps: [], conversationIDs: [], warnings: [])
        let transaction = try FileTransaction(parent: home.appendingPathComponent("transactions"), live: env.desktop, plan: plan)
        try MigrationBuilder.stage(changes, in: transaction); try await transaction.apply(stopped: {}); try transaction.commit()
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.desktop.appendingPathComponent("Local Storage").path))
        session.accountID = other
        let destination = try snapshot([key("synthetic-login"): Data("target-credential".utf8)])
        let restored = try read(ConversationPresentation.restoring(destination, sessions: [session], changes: [], environment: env))
        XCTAssertEqual(restored[key("synthetic-login")], Data("target-credential".utf8))
        let text = try ConversationPresentation.decode(XCTUnwrap(restored[pane]))
        XCTAssertTrue(text.contains("preserved")); XCTAssertTrue(text.contains("report.html")); XCTAssertFalse(text.contains("source-credential"))
        // Active presentation is conversation-owned and is not lost when a finished login backup is pruned.
        try transaction.discard()
        XCTAssertNotNil(try read(ConversationPresentation.restoring(destination, sessions: [session], changes: [], environment: env))[pane])
    }
}
