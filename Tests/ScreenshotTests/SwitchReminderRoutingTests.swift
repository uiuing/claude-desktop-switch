import XCTest
import SwitchCore
@testable import ClaudeSwitch

@MainActor
final class SwitchReminderRoutingTests: XCTestCase {
    private func fixture() throws -> (AppState, SwitchReminder) {
        let state = AppState(demo: true)
        state.updateSwitchReminder()
        return (state, try XCTUnwrap(state.switchReminder))
    }
    func testReviewPreparesConfirmationWithoutSwitchingOrTransferring() async throws {
        let (state, reminder) = try fixture()
        let active = state.activeID, sessions = state.inventory?.conversations.map(\.id)
        await state.reviewSwitchReminder(reminder.id)
        let operation = try XCTUnwrap(state.pending)
        XCTAssertEqual(operation.plan.kind, .switchAccount)
        XCTAssertEqual(operation.target.id, reminder.targetAccountID)
        XCTAssertEqual(state.activeID, active)
        XCTAssertEqual(state.inventory?.conversations.map(\.id), sessions)
        XCTAssertFalse(try XCTUnwrap(state.switchReminder).needsReview)
        XCTAssertFalse(state.canExecute)
        XCTAssertFalse(state.notifications.enabled)
    }
    func testOldNotificationCannotPrepareAfterSignOutOrQuotaExpiry() async throws {
        let (state, reminder) = try fixture()
        state.inventory?.signedIn = false
        await state.reviewSwitchReminder(reminder.id)
        XCTAssertNil(state.pending)
        XCTAssertNil(state.switchReminder)
        state.inventory?.signedIn = true
        for id in state.library.usage.keys {
            state.library.usage[id]?.observedAt = Date().addingTimeInterval(-3600)
            for index in state.library.usage[id]?.windows.indices ?? 0..<0 {
                state.library.usage[id]?.windows[index].observedAt = Date().addingTimeInterval(-3600)
            }
        }
        await state.reviewSwitchReminder(reminder.id)
        XCTAssertNil(state.pending)
    }
    func testReminderNeverReplacesAnotherConfirmation() async throws {
        let (state, reminder) = try fixture()
        await state.prepare(.switchAccount, target: state.library.accounts[2])
        let original = try XCTUnwrap(state.pending).id
        await state.reviewSwitchReminder(reminder.id)
        XCTAssertEqual(state.pending?.id, original)
    }
    func testNotificationWaitsForAWorkbenchAndThenOnlyPreviews() async throws {
        let (state, reminder) = try fixture()
        await state.openNotification(reminder.id)
        XCTAssertNil(state.pending)
        XCTAssertNotNil(state.notificationDestination)
        var opens = 0
        state.presentWorkbench = { opens += 1 }
        await state.openPendingNotification()
        XCTAssertGreaterThan(opens, 0)
        XCTAssertNil(state.notificationDestination)
        XCTAssertEqual(state.pending?.target.id, reminder.targetAccountID)
    }
}
