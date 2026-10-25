import XCTest
@testable import SwitchCore

final class ConversationTreeTests: XCTestCase {
    private func item(_ n: Int, parent: String? = nil, account: String = "source", archived: Bool = false) -> Conversation {
        let sid = String(format: "0a1b2c3d-1111-4aaa-8bbb-%012d", n)
        return Conversation(id: account + "/org/code/" + sid, sessionID: sid, accountID: account, organizationID: "org",
            title: "Fixture \(n)", kind: .code, modifiedAt: Date(timeIntervalSince1970: Double(n)),
            recordRelativePath: "fixture", cliSessionID: sid, archived: archived, parentSessionID: parent)
    }

    func testMainSelectionIncludesWholeTreeAndArchivedDependencies() throws {
        let root = item(1), child = item(2, parent: root.sessionID), grandchild = item(3, parent: child.sessionID)
        let archived = item(4, parent: root.sessionID, archived: true), unrelated = item(5)
        let tree = ConversationTree([grandchild, unrelated, archived, root, child])
        XCTAssertEqual(Set(tree.roots.map(\.id)), [root.id, unrelated.id])
        XCTAssertEqual(tree.root(of: grandchild).id, root.id)
        XCTAssertEqual(tree.childCount(of: root), 2)
        XCTAssertEqual(Set(try tree.expanded([root, child]).map(\.id)), [root.id, child.id, grandchild.id, archived.id])
        XCTAssertEqual(tree.modifiedAt(of: root), archived.modifiedAt)
    }

    func testMissingParentCrossAccountDuplicateAndCycleFailClosed() {
        let root = item(1), child = item(2, parent: root.sessionID)
        XCTAssertThrowsError(try ConversationTree([child]).expanded([child]))
        XCTAssertThrowsError(try ConversationTree([item(1, account: "other"), child]).expanded([child]))
        var duplicate = root; duplicate.id += "-duplicate"
        XCTAssertThrowsError(try ConversationTree([root, duplicate, child]).expanded([root]))
        var cycleRoot = root; cycleRoot.parentSessionID = child.sessionID
        let cycle = ConversationTree([cycleRoot, child])
        XCTAssertThrowsError(try cycle.expanded([cycleRoot]))
        XCTAssertEqual(cycle.visibleRoots.count, 2)
    }

    func testActiveChildKeepsArchivedAncestorReachableWithoutUnarchivingIt() throws {
        let root = item(1, archived: true), child = item(2, parent: root.sessionID)
        let tree = ConversationTree([root, child])
        XCTAssertEqual(tree.visibleRoots.map(\.id), [root.id])
        XCTAssertTrue(try XCTUnwrap(tree.expanded([child]).first { $0.id == root.id }).archived)
    }

    func testLineageMatchesNativePrecedenceAndDetachedMeaning() {
        let a = item(1).sessionID, b = item(2).sessionID, c = item(3).sessionID
        let source: JSONValue = .object(["spawnedFrom": .object(["sessionId": .string(a), "sideSession": .bool(true)]),
                                         "forkedFromSessionId": .string(b)])
        XCTAssertEqual(ConversationLineage.read(source, sessionID: c).parent, b)
        let detached: JSONValue = .object(["spawnedFrom": source["spawnedFrom"], "lineageDetached": .bool(true)])
        XCTAssertNil(ConversationLineage.read(detached, sessionID: c).parent)
        XCTAssertTrue(ConversationLineage.read(.object(["forkedFromSessionId": .string(c)]), sessionID: c).invalid)
        XCTAssertTrue(ConversationLineage.read(.object(["spawnedFrom": .string("unsupported")]), sessionID: c).invalid)
    }

    func testChildActivityAndLegacyChildFollowSelectTheRoot() {
        let now = Date(timeIntervalSince1970: 1000)
        let root = item(1)
        var child = item(2, parent: root.sessionID); child.modifiedAt = now.addingTimeInterval(-60)
        let rule = FollowRule(conversationID: child.id, sessionID: child.sessionID)
        let sessions = [child, root]
        XCTAssertEqual(SessionLibrary.followedSessions(sessions, rules: [rule], activeAccountID: "source", targetAccountID: "target").map(\.id), [root.id])
        XCTAssertEqual(SessionLibrary.switchCandidates(sessions, followed: [], activeAccountID: "source", now: now).map(\.id), [root.id])
        XCTAssertTrue(ConversationTree(sessions).recentlyActive(root, accountID: "source", now: now))
    }

    func testRetiredCopyPreferenceIsIgnoredAndNotWrittenAgain() throws {
        let old = Data(#"{"conversationID":"fixture","sessionID":"fixture","transferMode":"copy","mode":"selectedAccounts","targetAccountIDs":["target"]}"#.utf8)
        let rule = try JSONDecoder().decode(FollowRule.self, from: old)
        XCTAssertEqual(rule.mode, .selectedAccounts)
        XCTAssertEqual(rule.targetAccountIDs, ["target"])
        let saved = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(rule))
        XCTAssertNil(saved.object?["transferMode"])
    }

    func testTaskMenuCollapsesChildrenAndKeepsAttentionWithoutBorrowingTheirProcess() throws {
        let root = item(1), child = item(2, parent: root.sessionID), other = item(3, parent: root.sessionID)
        let tree = ConversationTree([root, child, other])
        let tasks = tree.mainTasks([CodeTask(conversation: child, status: .running, process: .init(pid: 50, started: 1)),
                                   CodeTask(conversation: root, status: .idle), CodeTask(conversation: other, status: .permission)])
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.conversation.id, root.id)
        XCTAssertEqual(tasks.first?.status, .permission)
        XCTAssertNil(tasks.first?.process)
    }
}
