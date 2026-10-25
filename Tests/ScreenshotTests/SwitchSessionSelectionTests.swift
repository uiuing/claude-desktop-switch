import XCTest
import SwitchCore
@testable import ClaudeSwitch

@MainActor
final class SwitchSessionSelectionTests: XCTestCase {
    private func encodedFollows(_ state: AppState) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state.library.follows)
    }

    func testPreviewDefaultsAndCancelKeepSavedRulesAndInventory() async throws {
        let state = AppState(demo: true)
        let before = try encodedFollows(state)
        let inventory = state.inventory?.conversations
        await state.prepare(.switchAccount, target: state.library.accounts[1])
        let operation = try XCTUnwrap(state.pending)
        XCTAssertEqual(operation.followCandidates?.map(\.id), ["demo-1", "demo-2", "demo-0"])
        XCTAssertEqual(Set(operation.sessions.map(\.id)), ["demo-0", "demo-1", "demo-2"])
        XCTAssertTrue(operation.selectionReady)

        await state.setPendingFollow(false, sessionID: "demo-1")
        await state.setPendingFollow(true, sessionID: "demo-0")
        XCTAssertEqual(state.pending?.id, operation.id)
        XCTAssertEqual(Set(try XCTUnwrap(state.pending).plan.conversationIDs), ["demo-0", "demo-2"])
        XCTAssertEqual(try encodedFollows(state), before)
        state.pending = nil
        XCTAssertEqual(try encodedFollows(state), before)
        XCTAssertEqual(state.inventory?.conversations, inventory)
        await state.prepare(.switchAccount, target: state.library.accounts[1])
        XCTAssertEqual(Set(try XCTUnwrap(state.pending).sessions.map(\.id)), ["demo-0", "demo-1", "demo-2"])
    }

    func testSelectionCanSwitchWithoutConversations() async throws {
        let state = AppState(demo: true)
        await state.prepare(.switchAccount, target: state.library.accounts[1])
        await state.setPendingFollow(true, sessionID: "demo-0")
        await state.setPendingFollow(false, sessionID: "demo-0")
        await state.setPendingFollow(true, sessionID: "demo-0")
        for id in ["demo-0", "demo-1", "demo-2"] { await state.setPendingFollow(false, sessionID: id) }
        let empty = try XCTUnwrap(state.pending)
        XCTAssertTrue(empty.sessions.isEmpty)
        XCTAssertTrue(empty.plan.conversationIDs.isEmpty)
        XCTAssertTrue(empty.selectionReady)
        XCTAssertEqual(empty.followCandidates?.count, 3)
        XCTAssertFalse(empty.plan.steps.contains(L10n.tr("Bring selected conversations and their subtasks to this account")))
    }

    func testInvalidFollowRemainsDeselectableAndSelectionFailureKeepsRules() async throws {
        let state = AppState(demo: true)
        let index = try XCTUnwrap(state.inventory?.conversations.firstIndex { $0.id == "demo-1" })
        state.inventory?.conversations[index].cliSessionID = nil
        let before = try encodedFollows(state)
        await state.prepare(.switchAccount, target: state.library.accounts[1])
        XCTAssertNotNil(state.pending?.selectionError)
        XCTAssertEqual(state.pending?.selectionReady, false)
        XCTAssertTrue(try XCTUnwrap(state.pending?.followCandidates).contains { $0.id == "demo-1" })
        await state.setPendingFollow(false, sessionID: "demo-1")
        XCTAssertEqual(state.pending?.selectionReady, true)
        XCTAssertEqual(state.pending?.plan.conversationIDs, ["demo-0", "demo-2"])
        await state.setPendingFollow(true, sessionID: "demo-1")
        XCTAssertEqual(state.pending?.selectionReady, false)
        XCTAssertEqual(try encodedFollows(state), before)
    }

    func testSuccessfulSelectionUpdatesOnlyEditedRulesAndExtendsRestrictedTarget() async throws {
        let state = AppState(demo: true)
        let recent = try XCTUnwrap(state.inventory?.conversations.first { $0.id == "demo-0" })
        let unrelated = try XCTUnwrap(state.inventory?.conversations.first { $0.id == "demo-3" })
        let otherTarget = state.library.accounts[2].id
        state.library.follows.append(FollowRule(conversationID: recent.id, sessionID: recent.sessionID,
                                                mode: .selectedAccounts, targetAccountIDs: [otherTarget]))
        state.library.follows.append(FollowRule(conversationID: unrelated.id, sessionID: unrelated.sessionID,
                                                mode: .selectedAccounts, targetAccountIDs: [otherTarget]))
        let target = state.library.accounts[1]
        await state.prepare(.switchAccount, target: target)
        XCTAssertEqual(state.library.follows.first { $0.matches(recent) }?.targetAccountIDs, [otherTarget])
        state.applySwitchFollowSelection(try XCTUnwrap(state.pending))
        XCTAssertEqual(state.library.follows.first { $0.matches(recent) }?.targetAccountIDs, [otherTarget, target.id].sorted())
        await state.setPendingFollow(false, sessionID: "demo-1")
        await state.setPendingFollow(true, sessionID: "demo-0")
        state.applySwitchFollowSelection(try XCTUnwrap(state.pending))
        XCTAssertFalse(state.library.follows.contains { $0.conversationID == "demo-1" })
        XCTAssertTrue(state.library.follows.contains { $0.conversationID == "demo-2" })
        XCTAssertEqual(state.library.follows.first { $0.matches(recent) }?.targetAccountIDs, [otherTarget, target.id].sorted())
        XCTAssertEqual(state.library.follows.first { $0.matches(recent) }?.mode, .selectedAccounts)
        XCTAssertEqual(state.library.follows.first { $0.matches(unrelated) }?.targetAccountIDs, [otherTarget])
    }

    func testAutomaticSelectionBecomesFollowAndUnknownRowsCannotEnterPlan() async throws {
        let state = AppState(demo: true)
        state.library.follows = []
        await state.prepare(.switchAccount, target: state.library.accounts[1])
        XCTAssertEqual(try XCTUnwrap(state.pending).sessions.map(\.id), ["demo-0"])
        await state.setPendingFollow(true, sessionID: "demo-3")
        XCTAssertEqual(try XCTUnwrap(state.pending).sessions.map(\.id), ["demo-0"])
        await state.setPendingFollow(true, sessionID: "demo-0")
        state.applySwitchFollowSelection(try XCTUnwrap(state.pending))
        XCTAssertEqual(state.library.follows.count, 1)
        XCTAssertEqual(state.library.follows.first?.conversationID, "demo-0")
        XCTAssertEqual(state.library.follows.first?.mode, .allSavedAccounts)
    }

    func testAllRecentlyActiveCurrentSessionsArePreselectedAndCanBeDeselected() async throws {
        let state = AppState(demo: true), now = Date()
        let base = try XCTUnwrap(state.inventory?.conversations.first { $0.id == "demo-0" })
        let recent = (0..<5).map { index -> Conversation in
            var item = base
            item.id = "recent-\(index)"
            item.sessionID = "0a1b2c3d-1111-4aaa-8bbb-00000000010\(index)"
            item.modifiedAt = now.addingTimeInterval(-Double(index * 30 + 1))
            return item
        }
        state.inventory?.conversations = recent
        state.library.follows = []
        await state.prepare(.switchAccount, target: state.library.accounts[1])
        let operation = try XCTUnwrap(state.pending)
        XCTAssertEqual(operation.followCandidates?.map(\.id), recent.map(\.id))
        XCTAssertEqual(operation.sessions.map(\.id), recent.map(\.id))
        XCTAssertTrue(operation.initialFollowIDs.isEmpty)
        XCTAssertTrue(state.library.follows.isEmpty)
        await state.setPendingFollow(false, sessionID: recent[3].id)
        XCTAssertFalse(try XCTUnwrap(state.pending).sessions.contains { $0.id == recent[3].id })
        XCTAssertTrue(state.pending?.selectionReady == true)
        XCTAssertTrue(state.library.follows.isEmpty)
        state.applySwitchFollowSelection(try XCTUnwrap(state.pending))
        XCTAssertEqual(Set(state.library.follows.map(\.sessionID)), Set(recent.filter { $0.id != recent[3].id }.map { Optional($0.sessionID) }))
    }

    func testOlderRecentCandidateStaysUncheckedWithoutAFollow() async throws {
        let state = AppState(demo: true)
        let index = try XCTUnwrap(state.inventory?.conversations.firstIndex { $0.id == "demo-0" })
        state.inventory?.conversations[index].modifiedAt = Date().addingTimeInterval(-301)
        state.library.follows = []
        await state.prepare(.switchAccount, target: state.library.accounts[1])
        XCTAssertTrue(try XCTUnwrap(state.pending?.followCandidates).contains { $0.id == "demo-0" })
        XCTAssertTrue(try XCTUnwrap(state.pending).sessions.isEmpty)
    }

    func testActiveChildSelectsWholeFamilyAndDeselectsAsOneChoice() async throws {
        let state = AppState(demo: true)
        let root = try XCTUnwrap(state.inventory?.conversations.first { $0.id == "demo-3" })
        state.inventory?.activeAccountID = root.accountID
        state.library.follows = []
        let child = try XCTUnwrap(state.inventory?.conversations.firstIndex { $0.id == "demo-child-1" })
        state.inventory?.conversations[child].modifiedAt = Date().addingTimeInterval(-30)
        await state.prepare(.switchAccount, target: state.library.accounts[0])
        let operation = try XCTUnwrap(state.pending)
        XCTAssertTrue(operation.selectionReady)
        XCTAssertFalse(try XCTUnwrap(operation.followCandidates).contains { $0.id.hasPrefix("demo-child-") })
        XCTAssertEqual(Set(operation.sessions.map(\.id)), ["demo-3", "demo-child-0", "demo-child-1"])
        XCTAssertEqual(state.conversationTree.childCount(of: root), 2)
        state.applySwitchFollowSelection(operation)
        XCTAssertEqual(state.library.follows.map(\.sessionID), [root.sessionID])
        await state.setPendingFollow(false, sessionID: root.id)
        XCTAssertTrue(try XCTUnwrap(state.pending).sessions.isEmpty)
        await state.setPendingFollow(true, sessionID: root.id)
        XCTAssertEqual(Set(try XCTUnwrap(state.pending).sessions.map(\.id)), ["demo-3", "demo-child-0", "demo-child-1"])
    }
}
