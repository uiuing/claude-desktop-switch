import XCTest
@testable import SwitchCore

final class SwitchReminderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func candidate(_ id: String, five: Double = 80, seven: Double = 80, age: TimeInterval = 0,
                           reset: TimeInterval? = 18000, organization: String = "organization-one", at time: Date? = nil) -> (account: Account, rows: [QuotaReadout]) {
        let now = time ?? self.now
        var account = Account(id: id, hasSnapshot: true)
        account.plan = "Pro"; account.organizationID = organization
        let snapshot = UsageSnapshot(accountID: id, observedAt: now.addingTimeInterval(-age), origin: .live, windows: [
            QuotaWindow(id: "five_hour", title: "Session", usedPercent: 100 - five, resetsAt: reset.map { now.addingTimeInterval($0) }),
            QuotaWindow(id: "seven_day", title: "Weekly", usedPercent: 100 - seven, resetsAt: now.addingTimeInterval(604800))])
        return (account, AccountQuotaPresentation.rows(accountID: id, snapshot: snapshot, active: id == "active", now: now))
    }
    private func ranking(five: Double = 10, seven: Double = 60, target: String = "backup", age: TimeInterval = 0,
                         reset: TimeInterval? = 18000, organization: String = "organization-one", at time: Date? = nil) -> AccountRankingResult {
        let now = time ?? self.now
        return AccountRanking.evaluate([candidate("active", five: five, seven: seven, age: age, reset: reset, organization: organization, at: now),
                                        candidate(target, age: age, at: now)], activeID: "active", now: now)
    }
    func testOneLowReminderSurvivesRereadsTargetChangesAndRestart() throws {
        var policy = SwitchReminderPolicy()
        let first = try XCTUnwrap(policy.evaluate(ranking(), now: now))
        XCTAssertTrue(first.shouldNotify)
        XCTAssertTrue(first.reminder.needsReview)
        let repeatRead = try XCTUnwrap(policy.evaluate(ranking(five: 8, target: "other-backup"), now: now))
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
        let rebound = try XCTUnwrap(policy.evaluate(ranking(), now: now))
        XCTAssertFalse(rebound.shouldNotify)
        XCTAssertEqual(rebound.reminder.id, empty.reminder.id)
        policy.acknowledge(empty.reminder.id)
        XCTAssertFalse(try XCTUnwrap(policy.evaluate(ranking(five: 0, reset: 18001), now: now)).reminder.needsReview)
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
        let later = now.addingTimeInterval(18001)
        XCTAssertTrue(try XCTUnwrap(policy.evaluate(ranking(at: later), now: later)).shouldNotify)
        XCTAssertTrue(try XCTUnwrap(policy.evaluate(ranking(organization: "organization-two", at: later), now: later)).shouldNotify)
    }
    func testUnknownResetRearmsOnlyAfterFreshRecovery() throws {
        var policy = SwitchReminderPolicy()
        _ = policy.evaluate(ranking(reset: nil), now: now)
        XCTAssertNil(policy.evaluate(ranking(five: 90, age: 601, reset: nil), now: now))
        XCTAssertFalse(try XCTUnwrap(policy.evaluate(ranking(reset: nil), now: now)).shouldNotify)
        XCTAssertNil(policy.evaluate(ranking(five: 15, reset: nil), now: now))
        XCTAssertFalse(try XCTUnwrap(policy.evaluate(ranking(reset: nil), now: now)).shouldNotify)
        XCTAssertNil(policy.evaluate(ranking(five: 16, reset: nil), now: now))
        XCTAssertTrue(try XCTUnwrap(policy.evaluate(ranking(reset: nil), now: now)).shouldNotify)
    }

    func testFirstReadingAtZeroDoesNotCreateALowWarningOnRebound() throws {
        var policy = SwitchReminderPolicy()
        let first = try XCTUnwrap(policy.evaluate(ranking(five: 0), now: now))
        policy.acknowledge(first.reminder.id)
        let rebound = try XCTUnwrap(policy.evaluate(ranking(five: 1, reset: 18001), now: now))
        XCTAssertFalse(rebound.shouldNotify)
        XCTAssertFalse(rebound.reminder.needsReview)
        XCTAssertEqual(rebound.reminder.id, first.reminder.id)
        XCTAssertFalse(rebound.reminder.exhausted)
    }

    func testDecliningQuotaAndResetCorrectionsKeepTheReviewedReminderAcrossRestarts() throws {
        var policy = SwitchReminderPolicy()
        let first = try XCTUnwrap(policy.evaluate(ranking(), now: now))
        policy.acknowledge(first.reminder.id)
        for left in stride(from: 9, through: 1, by: -1) {
            policy = try JSONDecoder().decode(SwitchReminderPolicy.self, from: JSONEncoder().encode(policy))
            let value = try XCTUnwrap(policy.evaluate(ranking(five: Double(left), reset: 18000 + Double(10 - left)), now: now))
            XCTAssertFalse(value.shouldNotify)
            XCTAssertFalse(value.reminder.needsReview)
            XCTAssertEqual(value.reminder.id, first.reminder.id)
        }
        let corrected = try XCTUnwrap(policy.evaluate(ranking(reset: 20000), now: now))
        XCTAssertFalse(corrected.shouldNotify)
        XCTAssertEqual(corrected.reminder.id, first.reminder.id)
    }

    func testWeeklyResetCorrectionsDoNotRepeatLowOrExhaustedWarnings() throws {
        var policy = SwitchReminderPolicy()
        var lowID: UUID?
        for left in stride(from: 5, through: 0, by: -1) {
            let offset = Double(5 - left)
            let time = now.addingTimeInterval(offset)
            let value = try XCTUnwrap(policy.evaluate(ranking(five: 80, seven: Double(left), at: time), now: time))
            XCTAssertEqual(value.shouldNotify, left == 5 || left == 0)
            if left == 5 { lowID = value.reminder.id }
            if left > 0 { XCTAssertEqual(value.reminder.id, lowID) }
            else { XCTAssertNotEqual(value.reminder.id, lowID) }
        }
    }

    func testMissingResetThenConfirmedResetDoesNotRepeatWarning() throws {
        var policy = SwitchReminderPolicy()
        let first = try XCTUnwrap(policy.evaluate(ranking(reset: nil), now: now))
        for reset in [18000.0, nil, 18001.0] as [TimeInterval?] {
            let value = try XCTUnwrap(policy.evaluate(ranking(reset: reset), now: now))
            XCTAssertFalse(value.shouldNotify)
            XCTAssertEqual(value.reminder.id, first.reminder.id)
        }
        let later = now.addingTimeInterval(18002)
        XCTAssertTrue(try XCTUnwrap(policy.evaluate(ranking(at: later), now: later)).shouldNotify)
    }

    func testResetCorrectionAcrossThePreviousBoundaryDoesNotRepeatExhaustion() throws {
        var policy = SwitchReminderPolicy()
        let first = try XCTUnwrap(policy.evaluate(ranking(five: 0, reset: 1), now: now))
        let later = now.addingTimeInterval(2)
        let corrected = try XCTUnwrap(policy.evaluate(ranking(five: 0, reset: 1, at: later), now: later))
        XCTAssertFalse(corrected.shouldNotify)
        XCTAssertEqual(corrected.reminder.id, first.reminder.id)
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

    func testUnusedBackupDoesNotExpireAReminderAtTenMinutes() throws {
        let activeID = "0a1b2c3d-1111-4aaa-8bbb-000000000001"
        let backupID = "0a1b2c3d-1111-4aaa-8bbb-000000000002"
        var unused = candidate(backupID, five: 100, age: 590, reset: nil)
        unused.rows[0].resetKnownAbsent = true
        let values = [candidate(activeID, five: 10), unused]
        var policy = SwitchReminderPolicy()
        let first = try XCTUnwrap(policy.evaluate(AccountRanking.evaluate(values, activeID: activeID, now: now), now: now))
        XCTAssertEqual(first.reminder.expiresAt, now.addingTimeInterval(600))
        let later = now.addingTimeInterval(20)
        let continued = try XCTUnwrap(policy.evaluate(AccountRanking.evaluate(values, activeID: activeID, now: later), now: later))
        XCTAssertEqual(continued.reminder.id, first.reminder.id)
        XCTAssertTrue(continued.reminder.needsReview)
        XCTAssertFalse(continued.shouldNotify)
    }

    func testUnusedBackupReminderEndsAtTheConfirmedWeeklyReset() throws {
        let activeID = "0a1b2c3d-1111-4aaa-8bbb-000000000001"
        let backupID = "0a1b2c3d-1111-4aaa-8bbb-000000000002"
        var unused = candidate(backupID, five: 100, age: 3600, reset: nil)
        unused.rows[0].resetKnownAbsent = true
        unused.rows[1].resetsAt = now.addingTimeInterval(90)
        let values = [candidate(activeID, five: 10), unused]
        var policy = SwitchReminderPolicy()
        let first = try XCTUnwrap(policy.evaluate(AccountRanking.evaluate(values, activeID: activeID, now: now), now: now))
        XCTAssertEqual(first.reminder.expiresAt, now.addingTimeInterval(90))
        let later = now.addingTimeInterval(91)
        XCTAssertNil(policy.evaluate(AccountRanking.evaluate(values, activeID: activeID, now: later), now: later))
    }
}
