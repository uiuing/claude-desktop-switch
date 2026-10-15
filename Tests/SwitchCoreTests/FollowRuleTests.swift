import Foundation
import XCTest
@testable import SwitchCore

final class FollowRuleTests: XCTestCase {
    private func session(_ account: String, date: Double = 1) -> Conversation {
        .init(id: account + "/org/code/shared", sessionID: "shared", accountID: account, organizationID: "org",
              title: "Session", kind: .code, modifiedAt: Date(timeIntervalSince1970: date), recordRelativePath: "unused", cliSessionID: "cli")
    }
    func testLegacyDefaultsAndFollowSurvivesMove() throws {
        let data = Data(#"{"conversationID":"a/org/code/shared","mode":"allSavedAccounts","targetAccountIDs":[]}"#.utf8)
        let rule = try JSONDecoder().decode(FollowRule.self, from: data)
        XCTAssertEqual(rule.transferMode, .move)
        let moved = session("b")
        XCTAssertTrue(rule.matches(moved))
        let following = SessionLibrary.followedSessions([moved], rules: [rule], activeAccountID: "b", targetAccountID: "c")
        XCTAssertEqual(following.map(\.id), [moved.id])
    }
    func testCopyFollowsCurrentOwnerInsteadOfStaleCopyAndStillUpdatesExistingTarget() {
        let a = session("a", date: 100), b = session("b", date: 10), c = session("c", date: 200)
        let rule = FollowRule(conversationID: a.id, sessionID: a.sessionID, transferMode: .copy)
        let following = SessionLibrary.followedSessions([a, b, c], rules: [rule], activeAccountID: "b", targetAccountID: "c")
        XCTAssertEqual(following.map(\.id), [b.id])
        var archived = b; archived.archived = true
        XCTAssertTrue(SessionLibrary.followedSessions([archived], rules: [rule], activeAccountID: "b", targetAccountID: "c").isEmpty)
    }
    func testCurrentSourceFollowsEvenWhenActivityTiesOrTargetLooksNewer() {
        let current = session("a", date: 1)
        let rule = FollowRule(conversationID: current.id, sessionID: current.sessionID)
        for date: Double in [1, 2] {
            let following = SessionLibrary.followedSessions([current, session("b", date: date)], rules: [rule], activeAccountID: "a", targetAccountID: "b")
            XCTAssertEqual(following.map(\.id), [current.id])
        }
    }
    func testFallbackNeverReplacesExistingTargetRegardlessOfTimestamps() {
        let source = session("a", date: 2)
        let rule = FollowRule(conversationID: source.id, sessionID: source.sessionID)
        for date: Double in [1, 2, 3] {
            for current: String? in ["c", nil] {
                XCTAssertTrue(SessionLibrary.followedSessions([source, session("b", date: date)], rules: [rule], activeAccountID: current, targetAccountID: "b").isEmpty)
            }
        }
        XCTAssertEqual(SessionLibrary.followedSessions([session("a", date: 1), session("b", date: 2)], rules: [rule], activeAccountID: "c", targetAccountID: "d").map(\.id), [session("b").id])
    }
    func testArchivedCurrentOrExistingArchivedTargetIsNotResurrected() {
        let old = session("a", date: 1)
        var archived = session("b", date: 2); archived.archived = true
        let rule = FollowRule(conversationID: old.id, sessionID: old.sessionID)
        XCTAssertTrue(SessionLibrary.followedSessions([old, archived], rules: [rule], activeAccountID: "b", targetAccountID: "c").isEmpty)
        XCTAssertTrue(SessionLibrary.followedSessions([old, archived], rules: [rule], activeAccountID: "c", targetAccountID: "b").isEmpty)
    }
    func testConflictingTranscriptStillReachesMigrationCollisionCheck() {
        let old = session("a", date: 1)
        var other = session("b", date: 2); other.cliSessionID = "different"
        let rule = FollowRule(conversationID: old.id, sessionID: old.sessionID)
        XCTAssertEqual(SessionLibrary.followedSessions([old, other], rules: [rule], activeAccountID: "a", targetAccountID: "b").map(\.id), [old.id])
    }
    func testSavedModeAndTargetRestrictionRoundTrip() throws {
        let a = session("a")
        let rule = FollowRule(conversationID: a.id, sessionID: a.sessionID, transferMode: .copy,
                              mode: .selectedAccounts, targetAccountIDs: ["b"])
        let restored = try JSONDecoder().decode(FollowRule.self, from: JSONEncoder().encode(rule))
        XCTAssertEqual(restored.transferMode, .copy)
        XCTAssertEqual(SessionLibrary.followedSessions([a], rules: [restored], activeAccountID: "a", targetAccountID: "b").count, 1)
        XCTAssertTrue(SessionLibrary.followedSessions([a], rules: [restored], activeAccountID: "a", targetAccountID: "c").isEmpty)
    }
}
