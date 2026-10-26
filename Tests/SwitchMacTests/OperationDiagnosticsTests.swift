import Foundation
import XCTest
import SwitchCore
import SwitchStorage
@testable import SwitchMac

final class OperationDiagnosticsTests: XCTestCase {
    func testMessagesPathsAndUnknownDomainsNeverReachDiagnostics() {
        let privateText = "synthetic-private-value"
        XCTAssertEqual(RuntimeFailure(SwitchError.blocked(privateText)).description, "blocked")
        XCTAssertEqual(RuntimeFailure(SwitchError.malformed(privateText)).description, "malformed")
        XCTAssertEqual(RuntimeFailure(SwitchError.missing(privateText)).description, "missing")
        XCTAssertEqual(RuntimeFailure(NSError(domain: privateText, code: 123,
            userInfo: [NSLocalizedDescriptionKey: privateText, NSFilePathErrorKey: privateText])).description, "other")
        XCTAssertEqual(RuntimeFailure(NSError(domain: NSCocoaErrorDomain, code: 260,
            userInfo: [NSLocalizedDescriptionKey: privateText, NSFilePathErrorKey: privateText])).description, "cocoa:260")
    }

    func testStructuredFailuresHaveFixedCategories() {
        XCTAssertEqual(RuntimeFailure(SwitchError.changed).description, "changed")
        XCTAssertEqual(RuntimeFailure(SwitchError.busy).description, "busy")
        XCTAssertEqual(RuntimeFailure(SwitchError.unsafePath).description, "unsafe-path")
        XCTAssertEqual(RuntimeFailure(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "private"))).description, "decoding")
        XCTAssertEqual(RuntimeFailure(EncodingError.invalidValue("private", .init(codingPath: [], debugDescription: "private"))).description, "encoding")
        XCTAssertEqual(RuntimeFailure(NSError(domain: NSPOSIXErrorDomain, code: 28)).description, "posix:28")
        XCTAssertEqual(RuntimeFailure(NSError(domain: NSOSStatusErrorDomain, code: -25308)).description, "osstatus:-25308")
    }

    func testStalePresentationBindingIdentifiesAffectedFollowWithoutPrivateOutput() throws {
        let home = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/diagnostic-fixtures/\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = MacEnvironment(home: home)
        let source = "0a1b2c3d-1111-4aaa-8bbb-000000000001", destination = "0a1b2c3d-1111-4aaa-8bbb-000000000002"
        let org = "0a1b2c3d-1111-4aaa-8bbb-000000000003", sid = "local_0a1b2c3d-1111-4aaa-8bbb-000000000010"
        let cli = "0a1b2c3d-1111-4aaa-8bbb-000000000011", previousCLI = "0a1b2c3d-1111-4aaa-8bbb-000000000012"
        let session = Conversation(id: "synthetic-index", sessionID: sid, accountID: source, organizationID: org,
            title: "Synthetic private title", kind: .code, modifiedAt: .distantPast, recordRelativePath: "unused", cliSessionID: cli)
        let pane = Data("_https://claude.ai\0".utf8) + Data([1]) + Data(ConversationPresentation.pane.utf8)
        let state: [String: Any] = ["state": ["currentSessionId": previousCLI, "fileTabs": [["path": "/fixture/report.html"]]]]
        let value = ConversationPresentation.encode(String(decoding: try JSONSerialization.data(withJSONObject: state), as: UTF8.self))
        let files = try LevelDBSnapshot.files([pane: value])
        let archive = files.map { ArchiveFile(path: ConversationPresentation.prefix + $0.key, data: $0.value, sha256: digest($0.value)) }
        let stored = ConversationPresentation.Saved(sessionID: sid, cliSessionID: previousCLI, files: archive)
        let path = try ConversationPresentation.relative(session, target: Account(id: source, organizationID: org))
        let file = try SafeFiles.child(path, of: environment.desktop)
        try SafeFiles.privateDirectory(file.deletingLastPathComponent())
        try SafeFiles.atomicWrite(JSONEncoder().encode(stored), to: file)
        let plan = OperationPlan(kind: .switchAccount, sourceAccountID: source, targetAccountID: destination,
            configDigest: "fixture", steps: [], conversationIDs: [session.id], warnings: [])
        let transaction = try FileTransaction(parent: environment.root.appendingPathComponent("transactions"), live: environment.desktop, plan: plan)
        transaction.journal.phase = "recovered"; try transaction.persist()
        let counts = SwitchDiagnostics.inspectSavedPresentation(files: files, sessions: [session], environment: environment,
            follows: [FollowRule(conversationID: session.id, sessionID: sid)])
        XCTAssertEqual(counts["invalid"], 1)
        XCTAssertEqual(counts["historyIDMismatches"], 1)
        XCTAssertEqual(counts["recentEmptyRollbacksForInvalidSource"], 1)
        XCTAssertEqual(counts["recentEmptyRollbacksForInvalidTarget"], 0)
        XCTAssertEqual(counts["recentEmptyRollbacksWithInvalidFollow"], 1)
        let report = String(decoding: try JSONSerialization.data(withJSONObject: ["presentation": counts,
            "operations": SwitchDiagnostics.recentOperations(environment: environment)]), as: UTF8.self)
        for privateValue in [source, destination, org, sid, cli, previousCLI, session.title, home.path] {
            XCTAssertFalse(report.contains(privateValue))
        }
        let target = Account(id: destination, organizationID: org)
        let targetPath = try ConversationPresentation.relative(session, target: target)
        XCTAssertThrowsError(try ConversationPresentation.changes(sessions: [session], sources: [:], target: target,
            environment: environment, expectations: ["presentation:" + targetPath: .absent]))
        XCTAssertEqual(try SafeFiles.read(file), try JSONEncoder().encode(stored))
    }
}
