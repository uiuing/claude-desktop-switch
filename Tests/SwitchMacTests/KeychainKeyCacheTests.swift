import XCTest
@testable import SwitchMac

final class KeychainKeyCacheTests: XCTestCase {
    func testOneApprovalIsSharedUntilCleared() throws {
        let access = KeychainKeyCache()
        var loads = 0
        let load: (Bool) throws -> Data = { allowed in
            loads += 1
            guard allowed else { throw UsageFailure.keychain }
            return Data("fixture-key".utf8)
        }
        XCTAssertThrowsError(try access.read(allowPrompt: false, load: load))
        XCTAssertFalse(access.available)
        _ = try access.read(allowPrompt: true, load: load)
        for _ in 0..<3 { _ = try access.read(allowPrompt: false, load: load) }
        XCTAssertEqual(loads, 2)
        XCTAssertTrue(access.available)
        access.clear()
        XCTAssertFalse(access.available)
        XCTAssertThrowsError(try access.read(allowPrompt: false, load: load))
        XCTAssertEqual(loads, 3)
    }

    func testFailedApprovalCanRecoverWithoutRememberingFailure() throws {
        let access = KeychainKeyCache()
        XCTAssertThrowsError(try access.read(allowPrompt: true) { _ in throw UsageFailure.keychain })
        XCTAssertFalse(access.available)
        _ = try access.read(allowPrompt: false) { allowed in
            XCTAssertFalse(allowed)
            return Data("fixture-key".utf8)
        }
        XCTAssertTrue(access.available)
    }

    func testSleepDuringAnApprovalDoesNotRetainTheLateResult() {
        let access = KeychainKeyCache()
        let started = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
        let done = expectation(description: "Approval completed")
        DispatchQueue.global().async {
            do {
                _ = try access.read(allowPrompt: true) { _ in
                    started.signal()
                    guard finish.wait(timeout: .now() + 3) == .success else { throw UsageFailure.keychain }
                    return Data("fixture-key".utf8)
                }
                XCTFail("An approval cleared during sleep must not report success")
            } catch { XCTAssertTrue(error is CancellationError) }
            done.fulfill()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 3), .success)
        access.clear()
        finish.signal()
        wait(for: [done], timeout: 4)
        XCTAssertFalse(access.available)
    }

    func testConcurrentRechecksShareOneReplacement() throws {
        let access = KeychainKeyCache()
        let old = try access.key(allowPrompt: true) { _ in Data("fixture-old-key".utf8) }
        let started = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
        let first = expectation(description: "Replacement authorized")
        DispatchQueue.global().async {
            do {
                let key = try access.key(allowPrompt: true, replacing: old) { allowed in
                    XCTAssertTrue(allowed)
                    started.signal()
                    guard finish.wait(timeout: .now() + 3) == .success else { throw UsageFailure.keychain }
                    return Data("fixture-new-key".utf8)
                }
                XCTAssertEqual(key.data, Data("fixture-new-key".utf8))
            } catch { XCTFail("Replacement should succeed") }
            first.fulfill()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 3), .success)
        let readers = (0..<4).map { expectation(description: "Waiting reader \($0)") }
        for reader in readers {
            DispatchQueue.global().async {
                do {
                    let key = try access.key(allowPrompt: true, replacing: old) { _ in
                        XCTFail("Concurrent rechecks must share the replacement")
                        throw UsageFailure.keychain
                    }
                    XCTAssertEqual(key.data, Data("fixture-new-key".utf8))
                } catch { XCTFail("Waiting reader should receive the replacement") }
                reader.fulfill()
            }
        }
        finish.signal()
        wait(for: [first] + readers, timeout: 4)
    }

    func testSleepInvalidatesARecheckBeforeItCanPrompt() throws {
        let access = KeychainKeyCache()
        let old = try access.key(allowPrompt: true) { _ in Data("fixture-key".utf8) }
        access.clear()
        XCTAssertThrowsError(try access.key(allowPrompt: true, replacing: old) { _ in
            XCTFail("A read from before sleep must not request new authorization")
            return Data("fixture-key".utf8)
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(access.available)
    }

    func testCredentialFailuresAreClearedWhenTheKeyChanges() throws {
        let access = KeychainKeyCache()
        let old = try access.key(allowPrompt: true) { _ in Data("fixture-old-key".utf8) }
        access.reject("fixture-credential-digest", using: old)
        let same = try access.key(allowPrompt: false, replacing: old) { _ in Data("fixture-old-key".utf8) }
        XCTAssertTrue(access.rejects("fixture-credential-digest", using: same))
        let renewed = try access.key(allowPrompt: true, replacing: same) { _ in Data("fixture-new-key".utf8) }
        XCTAssertFalse(access.rejects("fixture-credential-digest", using: renewed))
        access.reject("fixture-credential-digest", using: old)
        XCTAssertFalse(access.rejects("fixture-credential-digest", using: renewed))
    }
}
