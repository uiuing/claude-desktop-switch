import XCTest
@testable import ClaudeSwitch

@MainActor
final class StartupAccessTests: XCTestCase {
    private enum Denied: Error { case access }

    func testBothExistingPermissionsStartOnceWithoutPrompting() async {
        let gate = StartupAccess()
        var items: [StartupAccess.Item] = [], starts = 0
        let access: (StartupAccess.Item, Bool) async throws -> Void = { item, allowed in
            XCTAssertFalse(allowed); items.append(item)
        }
        let start: () async -> Void = { starts += 1 }
        await gate.check(using: access, start: start)
        await gate.check(using: access, start: start)
        await gate.authorize(using: access, start: start)
        XCTAssertEqual(items, [.quota, .vault])
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(gate.isReady)
    }

    func testQuotaPermissionAloneCannotStartVaultOperations() async {
        let gate = StartupAccess()
        var starts = 0
        await gate.check(using: { item, allowed in
            XCTAssertFalse(allowed)
            if item == .vault { throw Denied.access }
        }, start: { starts += 1 })
        XCTAssertEqual(gate.confirmedItems, [.quota])
        XCTAssertEqual(gate.phase, .authorizationRequired)
        XCTAssertFalse(gate.authorizationFailed)
        XCTAssertEqual(starts, 0)
        await gate.authorize(using: { item, allowed in
            XCTAssertTrue(allowed)
            if item == .vault { throw CancellationError() }
        }, start: { starts += 1 })
        XCTAssertFalse(gate.isReady)
        XCTAssertTrue(gate.authorizationFailed)
        await gate.authorize(using: { _, allowed in XCTAssertTrue(allowed) }, start: { starts += 1 })
        XCTAssertTrue(gate.isReady)
        XCTAssertEqual(starts, 1)
    }

    func testSilentCheckInventoriesBothItemsButDeniedApprovalStopsBeforeAnotherPrompt() async {
        let gate = StartupAccess()
        var items: [StartupAccess.Item] = []
        await gate.check(using: { item, allowed in
            XCTAssertFalse(allowed); items.append(item); throw Denied.access
        }, notificationChoice: { true }, start: { XCTFail("Missing access") })
        XCTAssertEqual(items, [.quota, .vault])
        items.removeAll()
        await gate.authorize(using: { item, allowed in
            XCTAssertTrue(allowed); items.append(item); throw Denied.access
        }, configureNotifications: { _ in XCTFail("Required permissions must finish first") }, start: { XCTFail("Denied access") })
        XCTAssertEqual(items, [.quota])
        XCTAssertTrue(gate.notificationChoiceNeeded)
    }

    func testSimultaneousScenesAndRepeatedClicksShareTheInFlightCheck() async {
        let gate = StartupAccess()
        let entered = expectation(description: "Checking permission")
        var continuation: CheckedContinuation<Void, Error>?
        var starts = 0
        let first = Task {
            await gate.check(using: { item, allowed in
                XCTAssertFalse(allowed)
                if item == .quota {
                    try await withCheckedThrowingContinuation { continuation = $0; entered.fulfill() }
                }
            }, start: { starts += 1 })
        }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(gate.phase, .checking)
        await gate.check(using: { _, _ in XCTFail("Duplicate check") }, start: { XCTFail("Early start") })
        await gate.authorize(using: { _, _ in XCTFail("Concurrent prompt") }, start: { XCTFail("Early start") })
        continuation?.resume()
        await first.value
        XCTAssertTrue(gate.isReady)
        XCTAssertEqual(starts, 1)
    }

    func testCanceledStartupDoesNotStartServicesAfterALatePermissionResult() async {
        let gate = StartupAccess()
        await Task {
            await gate.check(using: { _, _ in withUnsafeCurrentTask { $0?.cancel() } },
                             start: { XCTFail("Canceled access must not start services") })
        }.value
        XCTAssertFalse(gate.isReady)
    }

    func testFirstLaunchExplainsNotificationsEvenWhenKeychainAccessAlreadyWorks() async {
        let gate = StartupAccess()
        var requests: [Bool] = [], starts = 0
        await gate.check(using: { _, _ in }, notificationChoice: { true }, start: { starts += 1 })
        XCTAssertEqual(gate.confirmedItems, [.quota, .vault])
        XCTAssertFalse(gate.isReady)
        XCTAssertTrue(gate.wantsNotifications)
        await gate.authorize(using: { _, _ in }, configureNotifications: { requests.append($0) }, start: { starts += 1 })
        XCTAssertEqual(requests, [true])
        XCTAssertTrue(gate.isReady)
        XCTAssertFalse(gate.notificationChoiceNeeded)
        XCTAssertEqual(starts, 1)
    }

    func testDecliningNotificationsDoesNotBlockAccountFeatures() async {
        let gate = StartupAccess()
        await gate.check(using: { _, _ in }, notificationChoice: { true }, start: { XCTFail("Choice not made") })
        gate.wantsNotifications = false
        var starts = 0
        await gate.authorize(using: { _, _ in }, configureNotifications: { XCTAssertFalse($0) }, start: { starts += 1 })
        XCTAssertTrue(gate.isReady)
        XCTAssertEqual(starts, 1)
    }

    func testNotificationDenialDoesNotUndoGrantedKeychainAccess() async {
        let gate = StartupAccess()
        await gate.check(using: { _, _ in }, notificationChoice: { true }, start: { XCTFail("Choice not made") })
        var notificationGranted = true
        await gate.authorize(using: { _, _ in }, configureNotifications: { _ in notificationGranted = false }, start: {})
        XCTAssertFalse(notificationGranted)
        XCTAssertTrue(gate.isReady)
    }

    func testWakeRechecksBothKeysWithoutRepeatingNotificationOnboarding() async {
        let gate = StartupAccess(ready: true)
        await gate.recheck(using: { item, allowed in
            XCTAssertFalse(allowed)
            if item == .vault { throw Denied.access }
        }, start: { XCTFail("Vault access missing after wake") })
        XCTAssertFalse(gate.isReady)
        XCTAssertEqual(gate.confirmedItems, [.quota])
        await gate.authorize(using: { _, _ in }, configureNotifications: { _ in XCTFail("Notifications were already configured") }, start: {})
        XCTAssertTrue(gate.isReady)
    }

    func testDemoNeverChecksRealPermissionsOrStartsServices() async {
        let gate = StartupAccess(ready: true)
        await gate.check(using: { _, _ in XCTFail("Demo permission read") },
                         notificationChoice: { XCTFail("Demo notification read"); return true }, start: { XCTFail("Demo services") })
        let state = AppState(demo: true)
        await state.start()
        XCTAssertTrue(state.startupAccess.isReady)
    }
}
