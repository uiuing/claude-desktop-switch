import XCTest
import SwitchCore
@testable import SwitchMac

final class TransactionRetentionTests: XCTestCase {
    private let a = "0a1b2c3d-1111-4aaa-8bbb-000000000001", b = "0a1b2c3d-1111-4aaa-8bbb-000000000002"
    private let session = "claude-code-sessions/0a1b2c3d-1111-4aaa-8bbb-000000000001/0a1b2c3d-3333-4aaa-8bbb-000000000003/0a1b2c3d-4444-4aaa-8bbb-000000000004.json"

    private func environment() -> MacEnvironment {
        let home = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/transfer-fixtures/retention-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return MacEnvironment(home: home)
    }

    func testKeepsNewestLoginSwapsPerAccountAndAWeekOfEverythingElse() async throws {
        let env = environment(), now = Date()
        func transaction(source: String?, staging relative: String, phase: String, age days: Double) throws -> URL {
            let plan = OperationPlan(kind: .switchAccount, sourceAccountID: source, targetAccountID: b, configDigest: "", steps: [])
            let transaction = try FileTransaction(parent: env.root.appendingPathComponent("transactions"), live: env.desktop, plan: plan)
            try transaction.stage(relative: relative, data: Data("{}".utf8))
            transaction.journal.phase = phase
            transaction.journal.createdAt = now.addingTimeInterval(-days * 86_400)
            try transaction.persist()
            return transaction.root
        }
        let newestSwaps = try [1.0, 20].map { try transaction(source: a, staging: "config.json", phase: "committed", age: $0) }
        let olderSwap = try transaction(source: a, staging: "config.json", phase: "committed", age: 30)
        let onlySwapOfAnotherAccount = try transaction(source: b, staging: "config.json", phase: "committed", age: 60)
        let recentTransfer = try transaction(source: a, staging: session, phase: "committed", age: 2)
        let oldTransfer = try transaction(source: a, staging: session, phase: "committed", age: 8)
        let oldRollback = try transaction(source: a, staging: "config.json", phase: "recovered", age: 8)
        let unfinished = try transaction(source: a, staging: "config.json", phase: "applying", age: 90)

        let engine = SwitchEngine(environment: env, vault: CredentialVault(root: env.root.appendingPathComponent("vault")))
        try await engine.pruneTransactions(now: now)

        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        XCTAssertTrue(newestSwaps.allSatisfy(exists))
        XCTAssertFalse(exists(olderSwap))
        XCTAssertTrue(exists(onlySwapOfAnotherAccount))
        XCTAssertTrue(exists(recentTransfer))
        XCTAssertFalse(exists(oldTransfer))
        XCTAssertFalse(exists(oldRollback))
        XCTAssertTrue(exists(unfinished))
    }

    func testJournalRecordsTheClaudeVersionAndOlderJournalsStillOpen() throws {
        let env = environment(), parent = env.root.appendingPathComponent("transactions")
        let plan = OperationPlan(kind: .switchAccount, sourceAccountID: a, targetAccountID: b, configDigest: "", steps: [])
        let recorded = try FileTransaction(parent: parent, live: env.desktop, plan: plan, claudeVersion: "0.14.2")
        XCTAssertEqual(try FileTransaction(existing: recorded.root, live: env.desktop).journal.claudeVersion, "0.14.2")

        let id = UUID().uuidString, older = parent.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        let journal = #"{"schema":1,"id":"\#(id)","phase":"committed","targetAccountID":"\#(b)","createdAt":0,"entries":[]}"#
        try Data(journal.utf8).write(to: older.appendingPathComponent("journal.json"))
        XCTAssertNil(try FileTransaction(existing: older, live: env.desktop).journal.claudeVersion)
    }
}
