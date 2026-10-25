import XCTest
import SwitchCore
@testable import ClaudeSwitch

@MainActor
final class OperationFeedbackTests: XCTestCase {
    private let accountID = "0a1b2c3d-1111-4aaa-8bbb-000000000001"
    private let target = "mi•••el@gmail.com"
    private func plan(_ kind: OperationKind) -> OperationPlan {
        .init(kind: kind, sourceAccountID: nil, targetAccountID: accountID, configDigest: "fixture", steps: [])
    }
    private func rows(age: TimeInterval = 0, reset: TimeInterval = 3600, origin: UsageOrigin = .live) -> [QuotaReadout] {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = UsageSnapshot(accountID: accountID, observedAt: now.addingTimeInterval(-age), origin: origin,
            windows: [.init(id: "five_hour", title: "Session", usedPercent: 40, resetsAt: now.addingTimeInterval(reset)),
                      .init(id: "seven_day", title: "Weekly", usedPercent: 100, resetsAt: now.addingTimeInterval(reset))])
        return AccountQuotaPresentation.rows(accountID: accountID, snapshot: snapshot, active: false, now: now)
    }
    func testReplacingOrDismissingAMessageClearsItsPreviousResultStyle() {
        let state = AppState(demo: true)
        let failure = OperationFeedback.failed(kind: .switchAccount, target: target, reason: "fixture-error")
        state.showOperationFeedback(failure)
        XCTAssertEqual(state.operationFeedback?.style, .failure)
        state.message = "fixture-information"
        XCTAssertNil(state.operationFeedback)
        state.showOperationFeedback(failure)
        state.message = nil
        XCTAssertNil(state.operationFeedback)
    }
    func testSwitchIdentifiesTargetAndIncludesBothVerifiedLimitsIncludingZero() {
        let quota = rows()
        let result = OperationFeedback.completed(plan: plan(.switchAccount), target: target, quota: quota, result: .init())
        XCTAssertEqual(result.title, L10n.tr("Account switched"))
        XCTAssertTrue(result.body.contains(target))
        for row in quota {
            XCTAssertTrue(result.body.contains(L10n.tr("{0} remaining: {1}", L10n.argument(row.shortTitle), row.percentageText)))
        }
        XCTAssertTrue(result.body.contains(L10n.tr("Please check in Claude.")))
        XCTAssertFalse(result.requiresAttention)
    }
    func testUnknownStaleFutureResetAndNonOnlineQuotaNeverClaimCurrentRemaining() {
        for quota in [[], rows(age: 3600), rows(age: -3600), rows(reset: -1), rows(origin: .localCache)] {
            let result = OperationFeedback.completed(plan: plan(.switchAccount), target: target, quota: quota, result: .init())
            XCTAssertTrue(result.body.contains(L10n.tr("Quota not available yet.")))
            XCTAssertFalse(result.body.contains("%"))
        }
    }
    func testConversationCountDescribesTheSelectedPlanWithoutClaimingAnAccountSwitch() {
        var transfer = plan(.migrate)
        transfer.conversationIDs = ["fixture-a", "fixture-b", "fixture-c"]
        let result = OperationFeedback.completed(plan: transfer, target: target, quota: rows(), result: .init())
        XCTAssertEqual(result.title, L10n.tr("Conversations ready"))
        XCTAssertTrue(result.body.contains(L10n.tr("Conversations ready in {0}: {1}.", L10n.argument(target), L10n.argument(3))))
        XCTAssertFalse(result.body.contains(L10n.tr("Switched to {0}.", L10n.argument(target))))
        XCTAssertFalse(result.body.contains("%"))
    }
    func testManualOpenAndBackupWarningsRemainVisibleAndDoNotHideAppliedResult() {
        let result = OperationFeedback.completed(plan: plan(.switchAccount), target: target, quota: [],
                                                 result: .init(needsManualOpen: true, backupIncomplete: true))
        XCTAssertTrue(result.requiresAttention)
        XCTAssertTrue(result.body.contains(target))
        XCTAssertTrue(result.body.contains(L10n.tr("Claude could not reopen. Open it manually to check.")))
        XCTAssertTrue(result.body.contains(L10n.tr("The recovery backup could not be completed. Your data has been kept.")))
        XCTAssertFalse(result.body.contains(L10n.tr("Please check in Claude.")))
    }
    func testFailureKeepsDetailsInAppButNotInSystemNotification() {
        let reason = "fixture-private-error-detail"
        let result = OperationFeedback.failed(kind: .migrate, target: target, reason: reason)
        XCTAssertEqual(result.title, L10n.tr("Conversation transfer failed"))
        XCTAssertTrue(result.requiresAttention)
        XCTAssertTrue(result.body.contains(reason))
        XCTAssertTrue(result.notificationBody.contains(target))
        XCTAssertFalse(result.notificationBody.contains(reason))
    }
    func testCompletionUsesAccountDisplayPreferenceAndRejectsWrongAccountQuota() throws {
        let state = AppState(demo: true)
        let account = try XCTUnwrap(state.accounts.first)
        state.library.preferences.maskEmail = true
        state.library.usage[account.id]?.accountID = "0a1b2c3d-1111-4aaa-8bbb-000000000002"
        let result = OperationFeedback.completed(plan: plan(.switchAccount), target: state.identity(account),
                                                 quota: state.quotaRows(for: account.id), result: .init())
        XCTAssertTrue(result.notificationBody.contains(account.identity(maskingEmail: true)))
        XCTAssertTrue(result.notificationBody.contains(L10n.tr("Quota not available yet.")))
    }
}
