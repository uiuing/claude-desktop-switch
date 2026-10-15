import XCTest
import Security
import SwitchCore
@testable import SwitchMac

final class CredentialVaultAccessTests: XCTestCase {
    private enum Denied: Error { case access }
    private func root() -> URL {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/vault-access-fixtures/\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("vault")
    }

    func testOneVaultApprovalCoversSavingLoadingAndRecoveryEncryption() async throws {
        var reads: [(Bool, Bool)] = []
        let vault = CredentialVault(root: root()) { allowPrompt, create in
            reads.append((allowPrompt, create))
            guard allowPrompt else { throw Denied.access }
            return Data(repeating: 0x5a, count: 32)
        }
        do { try await vault.authorizeAccess(allowPrompt: false); XCTFail("Expected missing access") } catch is Denied {}
        try await vault.authorizeAccess(allowPrompt: true)
        for id in ["0a1b2c3d-1111-4aaa-8bbb-000000000001", "0a1b2c3d-1111-4aaa-8bbb-000000000002"] {
            let snapshot = LoginSnapshot(accountID: id, version: "0.14.2", createdAt: Date(),
                                         auth: ["lastKnownAccountUuid": .string(id)], files: [], directories: [])
            try await vault.save(snapshot)
            let restored = try await vault.load(accountID: id)
            XCTAssertEqual(restored.accountID, id)
        }
        let recovery = Data("fixture-recovery".utf8)
        let encrypted = try await vault.seal(recovery, context: "fixture")
        let decrypted = try await vault.unseal(encrypted, context: "fixture")
        XCTAssertEqual(decrypted, recovery)
        XCTAssertEqual(reads.count, 2)
        XCTAssertFalse(reads[0].0); XCTAssertFalse(reads[0].1)
        XCTAssertTrue(reads[1].0); XCTAssertTrue(reads[1].1)
        vault.clearAccess()
        do { _ = try await vault.unseal(encrypted, context: "fixture"); XCTFail("Sleep must clear access") } catch is Denied {}
        XCTAssertEqual(reads.count, 3)
        XCTAssertFalse(reads[2].0); XCTAssertFalse(reads[2].1)
        try await vault.authorizeAccess(allowPrompt: true)
        let recovered = try await vault.unseal(encrypted, context: "fixture")
        XCTAssertEqual(recovered, recovery)
        XCTAssertEqual(reads.count, 4)
    }

    func testInvalidVaultKeyIsNotCachedOrReplaced() async throws {
        var reads = 0
        let vault = CredentialVault(root: root()) { _, _ in reads += 1; return Data(repeating: 0, count: 16) }
        for _ in 0..<2 {
            do { try await vault.authorizeAccess(allowPrompt: true); XCTFail("Invalid key must fail closed") }
            catch is SwitchError {}
        }
        XCTAssertEqual(reads, 2)
    }

    func testMissingKeyCannotBeRecreatedOverSnapshotsOrRecoveryCopies() throws {
        for folder in ["vault", "transactions"] {
            let vaultRoot = root(), directory = vaultRoot.deletingLastPathComponent().appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("fixture-encrypted-data".utf8).write(to: directory.appendingPathComponent("fixture"))
            XCTAssertThrowsError(try CredentialVault.validateKeyCreation(root: vaultRoot))
        }
        XCTAssertNoThrow(try CredentialVault.validateKeyCreation(root: root()))
    }

    func testMissingProjectKeyPreservesSavedDataAndDoesNotCacheSuccess() async throws {
        for folder in ["vault", "transactions"] {
            let vaultRoot = root(), directory = vaultRoot.deletingLastPathComponent().appendingPathComponent(folder)
            let file = directory.appendingPathComponent("fixture"), original = Data("fixture-encrypted-data".utf8)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try original.write(to: file)
            var reads = 0, created = 0
            let vault = CredentialVault(root: vaultRoot) { _, create in
                try VaultKeychain.load(create: create, lookup: { service in
                    XCTAssertEqual(service, "io.github.uiuing.claude-desktop-switch.local-vault")
                    reads += 1; return .init(errSecItemNotFound)
                }, make: {
                    try CredentialVault.validateKeyCreation(root: vaultRoot)
                    created += 1
                    return .init(errSecSuccess, data: Data(repeating: 0x5a, count: 32))
                })
            }
            for _ in 0..<2 {
                do { try await vault.authorizeAccess(allowPrompt: true); XCTFail("Missing keys must block access") }
                catch {
                    XCTAssertEqual((error as? LocalizedError)?.errorDescription,
                                   L10n.tr("The saved-login encryption key is missing. Restore it from a backup before continuing."))
                }
            }
            XCTAssertEqual(reads, 2)
            XCTAssertEqual(created, 0)
            XCTAssertEqual(try Data(contentsOf: file), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["fixture"])
        }
    }
}
