import XCTest
@testable import ClaudeSwitch

@MainActor
final class StartupAccessTests: XCTestCase {
    private enum Denied: Error { case access }

    func testExistingPermissionStartsOnceWithoutPrompting() async {
        let gate = StartupAccess()
        var checks: [Bool] = [], starts = 0
        let access: (Bool) async throws -> Void = { checks.append($0) }
        let start: () async -> Void = { starts += 1 }
        await gate.check(using: access, start: start)
        await gate.check(using: access, start: start)
        await gate.authorize(using: access, start: start)
        XCTAssertEqual(checks, [false])
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(gate.isReady)
    }

    func testDenialAndCancellationStayBlockedUntilAnExplicitSuccessfulRetry() async {
        let gate = StartupAccess()
        var checks: [Bool] = [], starts = 0
        await gate.check(using: { checks.append($0); throw Denied.access }, start: { starts += 1 })
        XCTAssertEqual(gate.phase, .authorizationRequired)
        XCTAssertFalse(gate.authorizationFailed)
        XCTAssertEqual(starts, 0)
        // Another scene must not trigger another check or a permission prompt.
        await gate.check(using: { checks.append($0) }, start: { starts += 1 })
        XCTAssertEqual(checks, [false])
        await gate.authorize(using: { checks.append($0); throw CancellationError() }, start: { starts += 1 })
        XCTAssertFalse(gate.isReady)
        XCTAssertTrue(gate.authorizationFailed)
        XCTAssertEqual(starts, 0)
        await gate.authorize(using: { checks.append($0) }, start: { starts += 1 })
        XCTAssertEqual(checks, [false, true, true])
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(gate.isReady)
        XCTAssertFalse(gate.authorizationFailed)
    }

    func testSimultaneousScenesAndRepeatedClicksShareTheInFlightCheck() async {
        let gate = StartupAccess()
        let entered = expectation(description: "Checking permission")
        var continuation: CheckedContinuation<Void, Error>?
        var starts = 0
        let first = Task {
            await gate.check(using: { allowed in
                XCTAssertFalse(allowed)
                try await withCheckedThrowingContinuation {
                    continuation = $0
                    entered.fulfill()
                }
            }, start: { starts += 1 })
        }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(gate.phase, .checking)
        XCTAssertFalse(gate.isReady)
        await gate.check(using: { _ in XCTFail("Duplicate check") }, start: { XCTFail("Early start") })
        await gate.authorize(using: { _ in XCTFail("Concurrent prompt") }, start: { XCTFail("Early start") })
        continuation?.resume()
        await first.value
        XCTAssertTrue(gate.isReady)
        XCTAssertEqual(starts, 1)
    }

    func testCanceledStartupDoesNotStartServicesAfterALatePermissionResult() async {
        let gate = StartupAccess()
        var starts = 0
        await Task {
            await gate.check(using: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }, start: { starts += 1 })
        }.value
        XCTAssertFalse(gate.isReady)
        XCTAssertEqual(starts, 0)
    }

    func testDemoNeverChecksRealPermissionsOrStartsServices() async {
        let gate = StartupAccess(ready: true)
        await gate.check(using: { _ in XCTFail("Demo permission read") }, start: { XCTFail("Demo services") })
        XCTAssertTrue(gate.isReady)
        let state = AppState(demo: true)
        await state.start()
        XCTAssertTrue(state.startupAccess.isReady)
    }
}
