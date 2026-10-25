import XCTest
import SwitchCore
@testable import ClaudeSwitch

@MainActor
final class ConversationQueryTests: XCTestCase {
    func testArchivedMainWithVisibleChildRemainsSelectableAndFollowed() {
        let state = AppState(demo: true)
        var main = state.inventory!.conversations[0]; main.archived = true
        var child = main; child.id = "fixture-child"; child.sessionID = "0a1b2c3d-1111-4aaa-8bbb-000000000099"
        child.archived = false; child.parentSessionID = main.sessionID
        state.inventory!.conversations = [main, child]
        state.library.follows = [FollowRule(conversationID: main.id, sessionID: main.sessionID)]
        state.selectedSessionIDs = [main.id]
        XCTAssertEqual(state.sessions.map(\.id), [main.id])
        XCTAssertEqual(state.selectedSessions.map(\.id), [main.id])
        XCTAssertEqual(state.followedSessionCount, 1)
    }
    func testOnlyMainConversationsAreListedAndChildSearchFindsTheirMain() throws {
        let state = AppState(demo: true)
        XCTAssertFalse(state.sessions.contains { $0.id.hasPrefix("demo-child-") })
        let child = try XCTUnwrap(state.inventory?.conversations.firstIndex { $0.id == "demo-child-1" })
        state.inventory?.conversations[child].title = "Unique child fixture search"
        state.search = "Unique child fixture search"
        XCTAssertEqual(state.sessions.map(\.id), ["demo-3"])
        state.selectedSessionIDs = ["demo-3"]
        XCTAssertEqual(state.selectedSessions.map(\.id), ["demo-3"])
    }
    func testSearchKeepsTitleProjectAccountAndFilterBehavior() {
        let state = AppState(demo: true)
        var first = state.inventory!.conversations[0]
        first.title = "Cafe launch"; first.project = "/fixture/Packaging"
        var second = state.inventory!.conversations[5]
        second.title = "Release checklist"; second.project = "/fixture/Website"
        var archived = first; archived.id = "archived"; archived.archived = true
        var unknown = first; unknown.id = "unassigned"
        unknown.accountID = "0a1b2c3d-1111-4aaa-8bbb-000000000099"
        unknown.title = "Draft"; unknown.project = nil; unknown.kind = .cowork
        state.inventory!.conversations = [first, second, archived, unknown]

        for (query, expected) in [("CAFE", first.id), ("packaging", first.id), ("Website", second.id),
                                  ("outlook.com", second.id), (L10n.tr("Unassigned account"), unknown.id)] {
            state.search = query
            XCTAssertEqual(state.sessions.map(\.id), [expected])
        }
        state.search = "missing fixture"
        XCTAssertTrue(state.sessions.isEmpty)
        state.search = ""
        state.sessionFilter = .cowork
        XCTAssertEqual(state.sessions.map(\.id), [unknown.id])
        state.sessionFilter = nil; state.selectedAccountID = second.accountID
        XCTAssertEqual(state.sessions.map(\.id), [second.id])
        state.selectedAccountID = nil; state.library.preferences.sessionSort = .account
        XCTAssertEqual(state.sessions, SessionLibrary.sorted([first, second, unknown], order: .account, accounts: state.knownAccounts))
    }

    func testSearchUsesCurrentDisplayedIdentityWithoutStaleResults() {
        let state = AppState(demo: true)
        let session = state.inventory!.conversations[0]
        state.inventory!.conversations = [session]
        let index = state.library.accounts.firstIndex { $0.id == session.accountID }!
        state.library.accounts[index].observeEmail("qa•••xy@yahoo.com", verifiedAt: Date())
        state.library.preferences.maskEmail = false
        state.search = "yahoo.com"
        XCTAssertEqual(state.sessions.map(\.id), [session.id])
        for mask in [true, false] {
            state.library.preferences.maskEmail = mask
            state.search = state.identity(id: session.accountID)
            XCTAssertEqual(state.sessions.map(\.id), [session.id])
        }
        state.library.accounts[index].observeEmail("qa•••xy@outlook.com", verifiedAt: Date().addingTimeInterval(1))
        state.search = "yahoo.com"
        XCTAssertTrue(state.sessions.isEmpty)
        state.search = "outlook.com"
        XCTAssertEqual(state.sessions.map(\.id), [session.id])
    }

    func testFollowCountsPreserveLegacyRulesAndDeduplicateAccountCopies() {
        let state = AppState(demo: true)
        let original = state.inventory!.conversations
        var copy = original[0]; copy.id = "copied/" + copy.sessionID; copy.accountID = original[5].accountID
        var archived = original[4]; archived.archived = true
        state.inventory!.conversations = [original[0], copy, original[1], original[2], original[3], archived]
        state.library.follows = [
            FollowRule(conversationID: original[0].id, sessionID: original[0].sessionID),
            FollowRule(conversationID: "legacy/account/code/" + original[1].sessionID),
            FollowRule(conversationID: original[2].id),
            FollowRule(conversationID: original[3].id, sessionID: "local_0a1b2c3d-1111-4aaa-8bbb-000000000099"),
            FollowRule(conversationID: archived.id, sessionID: archived.sessionID),
        ]
        XCTAssertEqual(state.followedSessionCount, 3)
        XCTAssertTrue(state.follows(copy)); XCTAssertTrue(state.follows(original[1]))
        XCTAssertFalse(state.follows(original[3]))
        state.search = "missing fixture"; state.selectedAccountID = copy.accountID
        XCTAssertEqual(state.followedSessionCount, 3)
        state.toggleFollow(copy)
        XCTAssertEqual(state.followedSessionCount, 2)
        state.library.follows = []
        XCTAssertEqual(state.followedSessionCount, 0)
    }

    func testLargeFollowSelectionCountsUniqueUnarchivedSessions() {
        let state = AppState(demo: true)
        let template = state.inventory!.conversations[0]
        let sessions = (0..<5000).map { index in
            var session = template
            session.sessionID = String(format: "local_0a1b2c3d-1111-4aaa-8bbb-%012d", index + 1)
            session.id = "fixture/" + session.sessionID
            session.archived = index.isMultiple(of: 10)
            return session
        }
        state.inventory!.conversations = sessions
        state.library.follows = sessions.map { FollowRule(conversationID: $0.id, sessionID: $0.sessionID) }
        XCTAssertEqual(state.followedSessionCount, 4500)
    }
}
