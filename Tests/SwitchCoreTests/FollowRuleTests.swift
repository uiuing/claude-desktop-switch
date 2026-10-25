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
    func testSwitchCandidatesUnionFollowsWithThreeDistinctRecentCurrentSessions() {
        func item(_ id: String, date: Double) -> Conversation {
            var value = session("a", date: date)
            value.id = "a/org/code/" + id; value.sessionID = id
            return value
        }
        let newest = item("newest", date: 5), second = item("second", date: 4)
        let third = item("third", date: 3), fourth = item("fourth", date: 2), oldFollow = item("old", date: 1)
        var duplicate = newest; duplicate.id = "a/other-org/code/newest"
        var archived = item("archived", date: 9); archived.archived = true
        var cowork = item("cowork", date: 9); cowork.kind = .cowork
        var missingHistory = item("missing", date: 9); missingHistory.cliSessionID = nil
        var otherAccount = item("other", date: 9); otherAccount.accountID = "b"
        let all = [fourth, oldFollow, third, second, newest, duplicate, archived, cowork, missingHistory, otherAccount]
        let result = SessionLibrary.switchCandidates(all, followed: [second, oldFollow], activeAccountID: "a")
        XCTAssertEqual(result.map(\.sessionID), ["second", "old", "newest", "third"])
        XCTAssertFalse(result.contains { $0.sessionID == fourth.sessionID })
        XCTAssertEqual(SessionLibrary.switchCandidates(all, followed: [], activeAccountID: nil), [])
        XCTAssertEqual(SessionLibrary.switchCandidates([newest], followed: [], activeAccountID: "a"), [newest])
    }
    func testSwitchCandidatesKeepAuthoritativeFollowSourceAndTargetRestrictions() {
        let current = session("a", date: 1), stale = session("c", date: 10), target = session("b", date: 20)
        let restricted = FollowRule(conversationID: current.id, sessionID: current.sessionID,
                                    mode: .selectedAccounts, targetAccountIDs: ["c"])
        let sessions = [stale, target, current]
        let following = SessionLibrary.followedSessions(sessions, rules: [restricted], activeAccountID: "a", targetAccountID: "b")
        XCTAssertTrue(following.isEmpty)
        // A restricted recent session can still be offered unchecked for an explicit selection.
        XCTAssertEqual(SessionLibrary.switchCandidates(sessions, followed: following, activeAccountID: "a"), [current])
        var rule = restricted; rule.mode = .allSavedAccounts
        let selected = SessionLibrary.followedSessions(sessions, rules: [rule], activeAccountID: "a", targetAccountID: "b")
        XCTAssertEqual(SessionLibrary.switchCandidates(sessions, followed: selected, activeAccountID: "a"), [current])
    }

    func testSwitchCandidatesIncludeAllActivityWithinFiveMinutesBeyondTheTopThree() {
        let now = Date(timeIntervalSince1970: 1000)
        let sessions = [999.0, 998, 997, 996, 700, 699].enumerated().map { index, date -> Conversation in
            var item = session("a", date: date)
            item.sessionID = "recent-\(index)"; item.id = "a/org/code/" + item.sessionID
            return item
        }
        var duplicate = sessions[0]; duplicate.id = "a/other-org/code/" + duplicate.sessionID
        let candidates = SessionLibrary.switchCandidates(sessions + [duplicate], followed: [sessions[0]], activeAccountID: "a", now: now)
        XCTAssertEqual(candidates.map(\.sessionID), Array(sessions.prefix(5)).map(\.sessionID))
    }

    func testRecentSwitchActivityRejectsOldFutureArchivedForeignAndUntransferableSessions() {
        let now = Date(timeIntervalSince1970: 1000)
        for age in [0.0, 299, 300] {
            XCTAssertTrue(SessionLibrary.recentlyActiveForSwitch(session("a", date: 1000 - age), activeAccountID: "a", now: now))
        }
        for age in [-1.0, 300.001] {
            XCTAssertFalse(SessionLibrary.recentlyActiveForSwitch(session("a", date: 1000 - age), activeAccountID: "a", now: now))
        }
        let current = session("a", date: 999)
        var archived = current; archived.archived = true
        var cowork = current; cowork.kind = .cowork
        var chat = current; chat.kind = .chat
        var missing = current; missing.cliSessionID = nil
        for item in [archived, cowork, chat, missing, session("b", date: 999)] {
            XCTAssertFalse(SessionLibrary.recentlyActiveForSwitch(item, activeAccountID: "a", now: now))
        }
        XCTAssertFalse(SessionLibrary.recentlyActiveForSwitch(current, activeAccountID: nil, now: now))
    }
}
