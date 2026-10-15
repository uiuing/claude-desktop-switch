import XCTest
@testable import SwitchCore

final class SwitchReminderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func candidate(_ id: String, five: Double = 80, seven: Double = 80, age: TimeInterval = 0,
                           reset: TimeInterval? = 18000, organization: String = "organization-one") -> (account: Account, rows: [QuotaReadout]) {
        var account = Account(id: id, hasSnapshot: true)
        account.plan = "Pro"; account.organizationID = organization
        let snapshot = UsageSnapshot(accountID: id, observedAt: now.addingTimeInterval(-age), origin: .live, windows: [
            QuotaWindow(id: "five_hour", title: "Session", usedPercent: 100 - five, resetsAt: reset.map { now.addingTimeInterval($0) }),
            QuotaWindow(id: "seven_day", title: "Weekly", usedPercent: 100 - seven, resetsAt: now.addingTimeInterval(604800))])
        return (account, AccountQuotaPresentation.rows(accountID: id, snapshot: snapshot, active: id == "active", now: now))
    }
    private func ranking(five: Double = 14, seven: Double = 60, target: String = "backup", age: TimeInterval = 0,
                         reset: TimeInterval? = 18000, organization: String = "organization-one") -> AccountRankingResult {
        AccountRanking.evaluate([candidate("active", five: five, seven: seven, age: age, reset: reset, organization: organization),
                                 candidate(target, age: age)], activeID: "active", now: now)
    }
    func testOneLowReminderSurvivesRereadsTargetChangesAndRestart() throws {
        var policy = SwitchReminderPolicy()
        let first = try XCTUnwrap(policy.evaluate(ranking(), now: now))
        XCTAssertTrue(first.shouldNotify)
        XCTAssertTrue(first.reminder.needsReview)
        let repeatRead = try XCTUnwrap(policy.evaluate(ranking(five: 12, target: "other-backup"), now: now))
        XCTAssertFalse(repeatRead.shouldNotify)
        XCTAssertEqual(repeatRead.reminder.id, first.reminder.id)
        XCTAssertEqual(repeatRead.reminder.targetAccountID, "other-backup")
        policy.acknowledge(first.reminder.id)
        var restored = try JSONDecoder().decode(SwitchReminderPolicy.self, from: JSONEncoder().encode(policy))
        let afterRestart = try XCTUnwrap(restored.evaluate(ranking(), now: now))
        XCTAssertFalse(afterRestart.shouldNotify)
        XCTAssertFalse(afterRestart.reminder.needsReview)
    }
    func testExhaustionEscalatesOnceAndOldWarningDoesNotReturn() throws {
        var policy = SwitchReminderPolicy()
        let low = try XCTUnwrap(policy.evaluate(ranking(), now: now))
        policy.acknowledge(low.reminder.id)
        let empty = try XCTUnwrap(policy.evaluate(ranking(five: 0), now: now))
        XCTAssertTrue(empty.shouldNotify)
        XCTAssertTrue(empty.reminder.exhausted)
        XCTAssertNotEqual(empty.reminder.id, low.reminder.id)
        XCTAssertFalse(try XCTUnwrap(policy.evaluate(ranking(five: 0), now: now)).shouldNotify)
        XCTAssertFalse(try XCTUnwrap(policy.evaluate(ranking(), now: now)).shouldNotify)
    }
    func testStalenessAndMissingRecommendationsDoNotRearmNotifications() throws {
        var policy = SwitchReminderPolicy()
        let first = try XCTUnwrap(policy.evaluate(ranking(), now: now))
        XCTAssertEqual(first.reminder.expiresAt, now.addingTimeInterval(600))
        XCTAssertNil(policy.evaluate(ranking(age: 601), now: now))
        XCTAssertNil(policy.evaluate(ranking(five: 70), now: now))
        XCTAssertFalse(try XCTUnwrap(policy.evaluate(ranking(), now: now)).shouldNotify)
    }
    func testNewResetAndOrganizationStartDistinctEpisodes() throws {
        var policy = SwitchReminderPolicy()
        _ = policy.evaluate(ranking(), now: now)
        XCTAssertTrue(try XCTUnwrap(policy.evaluate(ranking(reset: 20000), now: now)).shouldNotify)
        XCTAssertTrue(try XCTUnwrap(policy.evaluate(ranking(organization: "organization-two"), now: now)).shouldNotify)
    }
    func testUnknownResetRearmsOnlyAfterFreshRecovery() throws {
        var policy = SwitchReminderPolicy()
        _ = policy.evaluate(ranking(reset: nil), now: now)
        XCTAssertNil(policy.evaluate(ranking(five: 90, age: 601, reset: nil), now: now))
        XCTAssertFalse(try XCTUnwrap(policy.evaluate(ranking(reset: nil), now: now)).shouldNotify)
        XCTAssertNil(policy.evaluate(ranking(five: 90, reset: nil), now: now))
        XCTAssertTrue(try XCTUnwrap(policy.evaluate(ranking(reset: nil), now: now)).shouldNotify)
    }
    func testWeeklyAndOpportunityWordingAreNotSessionWarnings() throws {
        var policy = SwitchReminderPolicy()
        let weekly = try XCTUnwrap(policy.evaluate(ranking(five: 90, seven: 5), now: now))
        XCTAssertEqual(weekly.reminder.kind, .weeklyLow)
        let opportunity = AccountRanking.evaluate([candidate("active", five: 50), candidate("backup", reset: 1800)], activeID: "active", now: now)
        let value = try XCTUnwrap(policy.evaluate(opportunity, now: now))
        XCTAssertEqual(value.reminder.kind, .expiring)
        XCTAssertFalse(value.reminder.exhausted)
    }
}
