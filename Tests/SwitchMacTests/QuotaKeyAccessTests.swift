import XCTest
@testable import SwitchMac

final class QuotaKeyAccessTests: XCTestCase {
    func testOneApprovalIsSharedUntilCleared() throws {
        let access = QuotaKeyAccess()
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
        let access = QuotaKeyAccess()
        XCTAssertThrowsError(try access.read(allowPrompt: true) { _ in throw UsageFailure.keychain })
        XCTAssertFalse(access.available)
        _ = try access.read(allowPrompt: false) { allowed in
            XCTAssertFalse(allowed)
            return Data("fixture-key".utf8)
        }
        XCTAssertTrue(access.available)
    }

    func testSleepDuringAnApprovalDoesNotRetainTheLateResult() {
        let access = QuotaKeyAccess()
        let started = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
        let done = expectation(description: "Approval completed")
        DispatchQueue.global().async {
            _ = try? access.read(allowPrompt: true) { _ in
                started.signal()
                guard finish.wait(timeout: .now() + 3) == .success else { throw UsageFailure.keychain }
                return Data("fixture-key".utf8)
            }
            done.fulfill()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 3), .success)
        access.clear()
        finish.signal()
        wait(for: [done], timeout: 4)
        XCTAssertFalse(access.available)
    }
}
