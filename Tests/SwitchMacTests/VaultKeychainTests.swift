import XCTest
import Security
@testable import SwitchMac

final class VaultKeychainTests: XCTestCase {
    private let fixtureKey = Data(repeating: 0x5a, count: 32)
    private let projectService = "io.github.uiuing.claude-desktop-switch.local-vault"

    func testExistingKeyReadsOnlyTheProjectItem() throws {
        var reads: [String] = []
        let key = try VaultKeychain.load(create: true, lookup: {
            reads.append($0); return .init(errSecSuccess, data: fixtureKey)
        }, make: { XCTFail("An existing key must not be replaced"); return .init(errSecNotAvailable) })
        XCTAssertEqual(key, fixtureKey)
        XCTAssertEqual(reads, [projectService])
    }

    func testFreshInstallCreatesOnlyAfterTheProjectItemIsConfirmedAbsent() throws {
        var reads: [String] = [], created = 0
        let key = try VaultKeychain.load(create: true, lookup: { reads.append($0); return .init(errSecItemNotFound) }, make: {
            XCTAssertEqual(reads, [projectService]); created += 1
            return .init(errSecSuccess, data: fixtureKey)
        })
        XCTAssertEqual(key, fixtureKey)
        XCTAssertEqual(reads, [projectService])
        XCTAssertEqual(created, 1)
    }

    func testSilentCheckNeverCreatesAMissingKey() {
        XCTAssertThrowsError(try VaultKeychain.load(create: false, lookup: {
            XCTAssertEqual($0, projectService); return .init(errSecItemNotFound)
        }, make: { XCTFail("A silent check must not create a key"); return .init(errSecNotAvailable) }))
    }

    func testDeniedOrFailedReadsNeverCreateAKey() {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled, errSecNotAvailable] {
            XCTAssertThrowsError(try VaultKeychain.load(create: true, lookup: {
                XCTAssertEqual($0, projectService); return .init(status)
            }, make: { XCTFail("A failed read must not create a key"); return .init(errSecNotAvailable) }))
        }
    }

    func testInvalidExistingOrCreatedKeysFailClosed() {
        for data in [nil, Data(), Data(repeating: 0, count: 16)] as [Data?] {
            XCTAssertThrowsError(try VaultKeychain.load(create: true, lookup: { _ in .init(errSecSuccess, data: data) },
                make: { XCTFail("An invalid key must not be replaced"); return .init(errSecNotAvailable) }))
            XCTAssertThrowsError(try VaultKeychain.load(create: true, lookup: { _ in .init(errSecItemNotFound) },
                make: { .init(errSecSuccess, data: data) }))
        }
    }

    func testDuplicateCreationReadsTheExistingProjectKeyWithoutRetryingCreation() throws {
        var reads: [String] = [], created = 0
        let key = try VaultKeychain.load(create: true, lookup: {
            reads.append($0)
            return reads.count == 1 ? .init(errSecItemNotFound) : .init(errSecSuccess, data: fixtureKey)
        }, make: { created += 1; return .init(errSecDuplicateItem) })
        XCTAssertEqual(key, fixtureKey)
        XCTAssertEqual(reads, [projectService, projectService])
        XCTAssertEqual(created, 1)
    }

    func testFailedCreationAndFailedRaceReadStopWithoutRetryLoops() {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled, errSecDuplicateItem] {
            var reads = 0, created = 0
            XCTAssertThrowsError(try VaultKeychain.load(create: true, lookup: { _ in
                reads += 1; return .init(errSecItemNotFound)
            }, make: { created += 1; return .init(status) }))
            XCTAssertEqual(reads, status == errSecDuplicateItem ? 2 : 1)
            XCTAssertEqual(created, 1)
        }
    }
}
