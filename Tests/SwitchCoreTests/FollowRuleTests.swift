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
