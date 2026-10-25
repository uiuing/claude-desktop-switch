import XCTest
import SwitchCore
@testable import ClaudeSwitch

@MainActor
final class NewAccountFollowUpTests: XCTestCase {
    private func fixture(verified: Bool = true) throws -> (AppState, Account, Account) {
        let state = AppState(demo: true)
        let source = try XCTUnwrap(state.activeAccount)
        let target = state.library.accounts[1]
        if verified { state.library.accounts[1].confirmOrganization(try XCTUnwrap(target.organizationID), at: Date()) }
        state.beginNewAccountFollowUp(sourceAccountID: source.id)
        state.inventory?.activeAccountID = target.id
        state.inventory?.lastKnownAccountID = target.id
        return (state, source, try XCTUnwrap(state.activeAccount))
    }
    func testSavedLoginOffersOnlyAPreviewWithOriginalSource() async throws {
        let (state, source, target) = try fixture()
        let original = try XCTUnwrap(state.inventory?.conversations.first { state.library.follows[0].matches($0) })
        var otherCopy = original
        otherCopy.id = "stale-copy"; otherCopy.accountID = state.library.accounts[2].id
        otherCopy.modifiedAt = Date().addingTimeInterval(60)
        state.inventory?.conversations.append(otherCopy)
        let before = state.inventory?.conversations.map(\.id)

        await state.acceptNewAccountLogin(target)

        let operation = try XCTUnwrap(state.pending)
        XCTAssertEqual(operation.plan.kind, .migrate)
        XCTAssertEqual(operation.target.id, target.id)
        XCTAssertEqual(operation.plan.sourceAccountID, target.id)
        XCTAssertEqual(operation.sessions.count, 2)
        XCTAssertTrue(operation.sessions.allSatisfy { $0.accountID == source.id })
        XCTAssertEqual(operation.newAccountFollowUpID, state.library.newAccountFollowUp?.id)
        XCTAssertEqual(state.inventory?.conversations.map(\.id), before)
        XCTAssertFalse(state.working)
        XCTAssertTrue(state.showsNewAccountFollowUp)
        XCTAssertFalse(state.canExecute)
        await state.executePending()
        XCTAssertEqual(state.pending?.id, operation.id)
    }
    func testOrganizationMayArriveAfterSaveWithoutLosingFollowUp() async throws {
        let (state, _, target) = try fixture(verified: false)
        await state.acceptNewAccountLogin(target)
        XCTAssertNil(state.pending)
        XCTAssertTrue(state.showsNewAccountFollowUp)
        XCTAssertTrue(state.newAccountFollowNeedsOrganization)
        XCTAssertEqual(state.library.newAccountFollowUp?.reviewOffered, false)
        state.library.accounts[1].confirmOrganization(try XCTUnwrap(target.organizationID), at: Date())
        await state.advanceNewAccountFollowUp()
        XCTAssertNotNil(state.pending)
        XCTAssertFalse(state.newAccountFollowNeedsOrganization)
    }
    func testCancelKeepsReviewEntryAndDoesNotOfferAgainAutomatically() async throws {
        let (state, _, target) = try fixture()
        await state.acceptNewAccountLogin(target)
        let first = try XCTUnwrap(state.pending?.id)
        state.pending = nil
        await state.advanceNewAccountFollowUp()
        await state.acceptNewAccountLogin(target)
        XCTAssertNil(state.pending)
        XCTAssertTrue(state.showsNewAccountFollowUp)
        await state.reviewNewAccountFollowUp()
        XCTAssertNotEqual(state.pending?.id, first)
        XCTAssertNotNil(state.pending)
    }
    func testRestartKeepsDeferredIntentAndDoesNotRepeatCanceledPreview() async throws {
        let (state, _, target) = try fixture(verified: false)
        await state.acceptNewAccountLogin(target)
        let restored = AppState(demo: true)
        restored.library = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state.library))
        restored.inventory = state.inventory
        XCTAssertTrue(restored.newAccountFollowNeedsOrganization)
        restored.library.accounts[1].confirmOrganization(try XCTUnwrap(target.organizationID), at: Date())
        await restored.advanceNewAccountFollowUp()
        XCTAssertNotNil(restored.pending)
        state.library = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(restored.library))
        await state.advanceNewAccountFollowUp()
        XCTAssertNil(state.pending)
        XCTAssertTrue(state.showsNewAccountFollowUp)
    }
    func testOrdinarySaveSameAccountAndNoFollowsDoNotCreateTransfer() async throws {
        let ordinary = AppState(demo: true)
        await ordinary.acceptNewAccountLogin(try XCTUnwrap(ordinary.activeAccount))
        XCTAssertNil(ordinary.pending)
        XCTAssertNil(ordinary.library.newAccountFollowUp)

        let (state, source, _) = try fixture()
        state.inventory?.activeAccountID = source.id
        await state.acceptNewAccountLogin(source)
        XCTAssertNil(state.library.newAccountFollowUp)
        XCTAssertNil(state.pending)

        let (empty, _, target) = try fixture()
        empty.library.follows = []
        await empty.acceptNewAccountLogin(target)
        XCTAssertNil(empty.library.newAccountFollowUp)
        XCTAssertNil(empty.pending)
    }
    func testArchivedAndRestrictedSessionsAreNotOffered() async throws {
        let (state, _, target) = try fixture()
        let first = state.library.follows[0]
        if let index = state.inventory?.conversations.firstIndex(where: { first.matches($0) }) {
            state.inventory?.conversations[index].archived = true
        }
        state.library.follows[1].mode = .selectedAccounts
        state.library.follows[1].targetAccountIDs = [state.library.accounts[2].id]
        await state.acceptNewAccountLogin(target)
        XCTAssertNil(state.pending)
        XCTAssertNil(state.library.newAccountFollowUp)
    }
    func testBusyAndAnotherSheetDeferWithoutReplacingAnOperation() async throws {
        let (state, _, target) = try fixture()
        state.showQuickFind = true
        await state.acceptNewAccountLogin(target)
        XCTAssertNil(state.pending)
        XCTAssertEqual(state.library.newAccountFollowUp?.reviewOffered, false)
        state.showQuickFind = false
        let other = PendingOperation(plan: OperationPlan(kind: .capture, sourceAccountID: target.id,
            targetAccountID: target.id, configDigest: "demo", steps: []), target: target, sessions: [])
        state.pending = other
        await state.advanceNewAccountFollowUp()
        XCTAssertEqual(state.pending?.id, other.id)
        state.pending = nil
        state.working = true
        await state.advanceNewAccountFollowUp()
        XCTAssertNil(state.pending)
        XCTAssertEqual(state.library.newAccountFollowUp?.reviewOffered, false)
        state.working = false
        await state.advanceNewAccountFollowUp()
        XCTAssertEqual(state.pending?.plan.kind, .migrate)
    }
    func testUnknownOrUnsavedLoginCannotResolveTarget() async throws {
        let (state, _, target) = try fixture()
        state.inventory?.signedIn = nil
        await state.acceptNewAccountLogin(target)
        XCTAssertNil(state.library.newAccountFollowUp?.targetAccountID)
        state.inventory?.signedIn = true
        var unsaved = target; unsaved.hasSnapshot = false
        await state.acceptNewAccountLogin(unsaved)
        XCTAssertNil(state.library.newAccountFollowUp?.targetAccountID)
        XCTAssertNil(state.pending)
    }
    func testReopeningSignInScreenAndRestartKeepTheOriginalSource() throws {
        let (state, source, _) = try fixture()
        let intent = try XCTUnwrap(state.library.newAccountFollowUp)
        state.beginNewAccountFollowUp(sourceAccountID: nil)
        XCTAssertEqual(state.library.newAccountFollowUp, intent)
        let restored = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state.library))
        XCTAssertEqual(restored.newAccountFollowUp?.sourceAccountID, source.id)
        XCTAssertNil(restored.newAccountFollowUp?.targetAccountID)
    }
    func testSwitchingAwayEndsWaitingFollowUp() async throws {
        let (state, source, target) = try fixture(verified: false)
        await state.acceptNewAccountLogin(target)
        state.inventory?.activeAccountID = source.id
        await state.advanceNewAccountFollowUp()
        XCTAssertNil(state.library.newAccountFollowUp)
        XCTAssertNil(state.pending)
    }
    func testOnlySuccessfulMatchingTransferClearsNotice() async throws {
        let (state, _, target) = try fixture()
        await state.acceptNewAccountLogin(target)
        let operation = try XCTUnwrap(state.pending)
        var unrelated = operation; unrelated.newAccountFollowUpID = UUID()
        state.completeNewAccountFollowUp(unrelated)
        XCTAssertTrue(state.showsNewAccountFollowUp)
        state.completeNewAccountFollowUp(operation)
        XCTAssertFalse(state.showsNewAccountFollowUp)
        XCTAssertNil(state.library.newAccountFollowUp)
    }
    func testLegacyLibraryLoadsWithoutFollowUp() throws {
        let data = try JSONEncoder().encode(LibraryState())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "newAccountFollowUp")
        let restored = try JSONDecoder().decode(LibraryState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(restored.newAccountFollowUp)
    }
}
