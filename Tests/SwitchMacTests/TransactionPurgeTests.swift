import XCTest
import SwitchCore
@testable import SwitchMac

final class TransactionPurgeTests: XCTestCase {
    private func transaction(phase: String) throws -> (FileTransaction, URL) {
        let home = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/transfer-fixtures/purge-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let live = home.appendingPathComponent("live"), parent = home.appendingPathComponent("transactions")
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        let plan = OperationPlan(kind: .switchAccount, sourceAccountID: UUID().uuidString.lowercased(),
                                 targetAccountID: UUID().uuidString.lowercased(), configDigest: "", steps: [])
        let transaction = try FileTransaction(parent: parent, live: live, plan: plan)
        try transaction.stage(relative: "config.json", data: Data("{}".utf8))
        transaction.journal.phase = phase; try transaction.persist()
        return (transaction, parent.appendingPathComponent(plan.id.uuidString))
    }

    func testPurgingTheOnlyLoginRemovesTheTransaction() async throws {
        let (transaction, root) = try transaction(phase: "recovered")
        try await transaction.purge(["staged", "quarantine"], vault: CredentialVault(root: root.appendingPathComponent("unused")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testUnfinishedTransactionIsKept() async throws {
        let (transaction, root) = try transaction(phase: "applying")
        do {
            try await transaction.purge(["staged"], vault: CredentialVault(root: root.appendingPathComponent("unused")))
            XCTFail("an unfinished transaction must keep its originals")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("staged/config.json").path))
    }
}
