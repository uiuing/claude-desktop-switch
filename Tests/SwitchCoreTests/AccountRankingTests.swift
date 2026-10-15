import XCTest
@testable import SwitchCore

final class AccountRankingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private typealias Candidate = (account: Account, rows: [QuotaReadout])

    private func candidate(_ id: String, plan: String? = "Pro", five: Double? = 80, seven: Double? = 80,
                           age: TimeInterval = 0, fiveReset: TimeInterval? = 18000, sevenReset: TimeInterval = 604800,
                           invalid: Bool = false, origin: UsageOrigin = .live) -> Candidate {
        var account = Account(id: id, hasSnapshot: true)
        account.plan = plan
        account.loginInvalidAt = invalid ? now : nil
        let windows = [("five_hour", five, fiveReset), ("seven_day", seven, Optional(sevenReset))].compactMap { id, left, reset -> QuotaWindow? in
            guard let left else { return nil }
            return QuotaWindow(id: id, title: id, usedPercent: 100 - left,
                               resetsAt: reset.map { now.addingTimeInterval($0) }, resetKnownAbsent: reset == nil)
        }
        let snapshot = UsageSnapshot(accountID: id, observedAt: now.addingTimeInterval(-age), origin: origin, windows: windows)
        return (account, AccountQuotaPresentation.rows(accountID: id, snapshot: snapshot, active: false, now: now))
    }
    private func rank(_ values: [Candidate], active: String? = nil) -> AccountRankingResult {
        AccountRanking.evaluate(values, activeID: active, now: now)
    }

    func testCapacityBeatsRawPercentageAndPinningDoesNotChangeScore() throws {
        let result = rank([candidate("pro", five: 90), candidate("max", plan: "Max 20x", five: 40)], active: "pro")
        XCTAssertEqual(result.ranked.map(\.account.id), ["max", "pro"])
        XCTAssertEqual(result.displayAccounts.map(\.id), ["pro", "max"])
        XCTAssertEqual(try XCTUnwrap(result.ranked.first?.score), 8, accuracy: 1e-9)
        XCTAssertEqual(result.bestBackup?.account.id, "max")
        XCTAssertNil(result.advice)
    }

    func testWeeklyReserveDiscountAndExhaustionCannotBeHiddenByLargePlan() throws {
        let result = rank([candidate("low-week", plan: "Max 20x", five: 90, seven: 1),
                           candidate("balanced", plan: "Max 5x", five: 60, seven: 60),
                           candidate("exhausted", plan: "Max 20x", five: 100, seven: 0)])
        XCTAssertEqual(result.ranked.map(\.account.id), ["balanced", "low-week", "exhausted"])
        XCTAssertEqual(try XCTUnwrap(result.ranked[1].score), 0.9, accuracy: 1e-9)
        XCTAssertEqual(result.ranked.last?.availability, .exhausted)
        XCTAssertEqual(result.ranked.last?.score, 0)
    }

    func testKnownAndUnknownPlansAreNotSilentlyEquated() {
        for plan in [nil, "Team", "Enterprise", "Free", "Max", "Max 40x"] as [String?] {
            XCTAssertNil(AccountRanking.sessionMultiplier(plan: plan))
            let result = rank([candidate("unknown", plan: plan, five: 100), candidate("known", five: 40)])
            XCTAssertEqual(result.ranked.first?.account.id, "known")
            XCTAssertNil(result.ranked.last?.score)
            XCTAssertNotNil(result.ranked.last?.relativeScore)
        }
        let unknowns = rank([candidate("less", plan: "Team", five: 40), candidate("more", plan: "Team", five: 80)])
        XCTAssertEqual(unknowns.ranked.map(\.account.id), ["more", "less"])
    }

    func testNoProactivePlanComparisonWithoutAMultiplier() {
        XCTAssertNil(rank([candidate("active", plan: "Team", five: 10), candidate("backup", five: 95)], active: "active").advice)
        XCTAssertNil(rank([candidate("active", five: 10), candidate("backup", plan: "Team", five: 95)], active: "active").advice)
    }

    func testOnlyTheRankedBackupCanBeRecommended() {
        let result = rank([candidate("active", plan: "Max 20x", five: 14, seven: 58),
                           candidate("max-five", plan: "Max 5x", five: 92, seven: 83),
                           candidate("pro", five: 100, seven: 90)], active: "active")
        XCTAssertEqual(result.bestBackup?.account.id, "max-five")
        XCTAssertEqual(result.advice?.accountID, result.bestBackup?.account.id)
        XCTAssertEqual(result.displayAccounts.map(\.id), ["active", "max-five", "pro"])
    }

    func testLowerCapacityNeverReplacesHigherCapacityJustBecauseItsPercentageIsHigher() {
        let result = rank([candidate("active", plan: "Max 20x", five: 14), candidate("backup", five: 100)], active: "active")
        XCTAssertNil(result.advice)
    }

    func testCrossPlanAdviceDoesNotTradeAwayUnknownWeeklyCapacity() {
        let result = rank([candidate("active", five: 10, seven: 90),
                           candidate("backup", plan: "Max 20x", five: 90, seven: 30)], active: "active")
        XCTAssertEqual(result.bestBackup?.account.id, "backup")
        XCTAssertNil(result.advice)
    }

    func testSmallGainsAndHealthyCurrentAccountsDoNotPromptASwitch() {
        XCTAssertNil(rank([candidate("active", five: 15), candidate("backup", five: 30)], active: "active").advice)
        XCTAssertNil(rank([candidate("active", five: 60), candidate("backup", five: 100)], active: "active").advice)
    }

    func testExhaustionDoesNotWaitForImminentResetOrRequireKnownPlan() {
        let result = rank([candidate("active", five: 0, fiveReset: 60),
                           candidate("backup", plan: "Team", five: 30, seven: 5)], active: "active")
        XCTAssertEqual(result.advice?.accountID, "backup")
        let weekly = rank([candidate("active", five: 100, seven: 0, sevenReset: 60), candidate("backup")], active: "active")
        XCTAssertEqual(weekly.advice?.accountID, "backup")
    }

    func testNoRecommendationWithNoActiveOrNoUsableBackup() {
        XCTAssertNil(rank([candidate("only")]).advice)
        XCTAssertNil(rank([candidate("only", five: 0)], active: "only").bestBackup)
        XCTAssertNil(rank([candidate("active", five: 0), candidate("backup", seven: 0)], active: "active").advice)
    }

    func testMissingStaleFutureAndElapsedReadingsNeverDriveAdvice() {
        let invalid = [candidate("missing", seven: nil), candidate("stale", age: 601),
                       candidate("future", age: -1), candidate("reset", fiveReset: 0),
                       candidate("local", origin: .localCache), candidate("estimated", origin: .estimate)]
        for value in invalid {
            let result = rank([candidate("active", five: 0), value], active: "active")
            XCTAssertNil(result.advice, value.account.id)
            XCTAssertEqual(result.ranked.first { $0.account.id == value.account.id }?.availability, .needsRefresh)
        }
    }

    func testStaleReadingsRetainRelativeDisplayOrderWithoutDrivingAdvice() {
        let result = rank([candidate("a", five: 20, age: 3600), candidate("z", plan: "Max 5x", five: 80, age: 3600)])
        XCTAssertEqual(result.ranked.map(\.account.id), ["z", "a"])
        XCTAssertTrue(result.ranked.allSatisfy { $0.availability == .needsRefresh })
        XCTAssertNil(result.bestBackup)
    }

    func testFreshnessIsCheckedForEachWindowEvenWithAFreshSnapshot() {
        var value = candidate("backup")
        value.rows[1].observedAt = now.addingTimeInterval(-601)
        XCTAssertNil(rank([candidate("active", five: 0), value], active: "active").advice)
        value.rows[1].observedAt = now.addingTimeInterval(-600)
        XCTAssertEqual(rank([candidate("active", five: 0), value], active: "active").advice?.accountID, "backup")
    }

    func testAdviceRechecksTheAgeOfAPreviouslyComputedRanking() {
        let result = rank([candidate("active", five: 0), candidate("backup")], active: "active")
        XCTAssertNotNil(result.advice)
        XCTAssertNil(SwitchAdvisor.advice(active: result.ranked.first { $0.account.id == "active" },
                                         target: result.bestBackup, now: now.addingTimeInterval(601)))
    }

    func testExpiryRequiresKnownCurrentResetOrAnUntouchedSession() {
        let unknown = rank([candidate("active", fiveReset: nil),
                            candidate("backup", five: 90, seven: 90, fiveReset: 1800)], active: "active")
        XCTAssertNil(unknown.advice)
        let untouched = rank([candidate("active", five: 100, fiveReset: nil),
                              candidate("backup", five: 100, fiveReset: 1800)], active: "active")
        XCTAssertEqual(untouched.advice?.accountID, "backup")
        var estimated = candidate("active")
        estimated.rows[0].resetIsEstimate = true
        XCTAssertNil(rank([estimated, candidate("backup", five: 90, seven: 90, fiveReset: 1800)], active: "active").advice)
    }

    func testInvalidAndUnsavedLoginsStayUnavailable() {
        var unsaved = candidate("unsaved"); unsaved.account.hasSnapshot = false
        let result = rank([candidate("active", five: 0), candidate("invalid", invalid: true), unsaved], active: "active")
        XCTAssertNil(result.bestBackup)
        XCTAssertNil(result.advice)
        XCTAssertEqual(result.ranked.filter { $0.availability == .unavailable }.count, 2)
    }

    func testUnknownAndZeroAreDifferentStates() {
        let result = rank([candidate("unknown", five: nil), candidate("zero", five: 0)])
        XCTAssertEqual(result.ranked.map(\.availability), [.needsRefresh, .exhausted])
        XCTAssertNil(result.ranked[0].score)
        XCTAssertEqual(result.ranked[1].score, 0)
    }

    func testUnusedSessionWithNoResetIsUsable() {
        let result = rank([candidate("active", five: 0), candidate("unused", five: 100, fiveReset: nil)], active: "active")
        XCTAssertEqual(result.advice?.accountID, "unused")
        XCTAssertTrue(result.bestBackup?.window("five_hour")?.awaitingFirstUse == true)
    }

    func testExtraModelLimitDoesNotBlockTheGeneralAccountRanking() {
        var value = candidate("backup")
        var opus = value.rows[1]; opus.id = "seven_day_opus"; opus.remainingPercent = 0
        value.rows.append(opus)
        XCTAssertEqual(rank([candidate("active", five: 0), value], active: "active").advice?.accountID, "backup")
    }

    func testDuplicateOrMalformedRequiredReadingsFailClosed() {
        var duplicate = candidate("duplicate"); duplicate.rows.append(duplicate.rows[0])
        XCTAssertEqual(rank([duplicate]).ranked.first?.availability, .needsRefresh)
        for invalid in [Double.nan, Double.infinity, -1, 101] {
            var value = candidate("invalid"); value.rows[0].remainingPercent = invalid
            XCTAssertEqual(rank([value]).ranked.first?.availability, .needsRefresh)
            XCTAssertNil(rank([value]).ranked.first?.score)
        }
    }

    func testResetBonusRespectsClearCapacityAdvantagesAndSwitchBuffer() {
        let result = rank([candidate("high", five: 90), candidate("soon", five: 80, fiveReset: 1800)])
        XCTAssertEqual(result.ranked.first?.account.id, "high")
        let tied = rank([candidate("a", five: 80), candidate("z", five: 80, fiveReset: 1800)])
        XCTAssertEqual(tied.ranked.first?.account.id, "z")
        let tooSoon = rank([candidate("a", five: 80), candidate("z", five: 80, fiveReset: 60)])
        XCTAssertEqual(tooSoon.ranked.first?.account.id, "a")
    }

    func testSessionResetChangesTheMainScoreAndTheRecommendedBackup() throws {
        let result = rank([candidate("active", five: 10),
                           candidate("soon", five: 80, fiveReset: 1800, sevenReset: 6 * 86400),
                           candidate("later", five: 82, fiveReset: 14400, sevenReset: 6 * 86400)], active: "active")
        let soon = try XCTUnwrap(result.ranked.first { $0.account.id == "soon" })
        let later = try XCTUnwrap(result.ranked.first { $0.account.id == "later" })
        XCTAssertEqual(try XCTUnwrap(soon.baseScore), 0.8, accuracy: 1e-9)
        XCTAssertEqual(soon.resetBonus, 0.072, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(soon.score), 0.8576, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(later.score), 0.833448, accuracy: 1e-9)
        XCTAssertLessThan(try XCTUnwrap(soon.baseScore), try XCTUnwrap(later.baseScore))
        XCTAssertEqual(result.bestBackup?.account.id, "soon")
        XCTAssertEqual(result.advice?.accountID, "soon")
    }

    func testBothResetWindowsContributeAcrossTheirFullPeriods() throws {
        let session = rank([candidate("later", fiveReset: 14400), candidate("sooner", fiveReset: 7200)])
        XCTAssertEqual(session.ranked.first?.account.id, "sooner")
        XCTAssertGreaterThan(try XCTUnwrap(session.ranked[0].score), try XCTUnwrap(session.ranked[1].score))
        let weekly = rank([candidate("later", sevenReset: 6 * 86400), candidate("sooner", sevenReset: 86400)])
        XCTAssertEqual(weekly.ranked.first?.account.id, "sooner")
        XCTAssertGreaterThan(try XCTUnwrap(weekly.ranked[0].score), try XCTUnwrap(weekly.ranked[1].score))
    }

    func testResetOpportunitiesAreNotAddedTwice() throws {
        let session = try XCTUnwrap(rank([candidate("a", fiveReset: 1800)]).ranked.first)
        let weekly = try XCTUnwrap(rank([candidate("a", sevenReset: 86400)]).ranked.first)
        let both = try XCTUnwrap(rank([candidate("a", fiveReset: 1800, sevenReset: 86400)]).ranked.first)
        XCTAssertEqual(both.resetBonus, max(session.resetBonus, weekly.resetBonus), accuracy: 1e-9)
        XCTAssertLessThan(both.resetBonus, session.resetBonus + weekly.resetBonus)
    }

    func testBonusFadesWhenThereIsTooLittleTimeAfterSwitching() throws {
        func bonus(_ seconds: Double) throws -> Double {
            try XCTUnwrap(rank([candidate("a", fiveReset: seconds)]).ranked.first).resetBonus
        }
        XCTAssertGreaterThan(try bonus(1200), try bonus(600))
        XCTAssertGreaterThan(try bonus(600), try bonus(301))
        for seconds in [300.0, 60, 0, -60, 18000, 36000] {
            XCTAssertEqual(try bonus(seconds), 0)
        }
    }

    func testUnknownEstimatedStaleOrBlockedReadingsGetNoResetBonus() throws {
        var estimated = candidate("estimate", fiveReset: 1800)
        estimated.rows[0].resetIsEstimate = true
        for value in [estimated, candidate("unknown", fiveReset: nil), candidate("missing", seven: nil, fiveReset: 1800),
                      candidate("stale", age: 601, fiveReset: 1800, sevenReset: 86400),
                      candidate("zero", five: 0, fiveReset: 1800, sevenReset: 86400),
                      candidate("weekly-zero", seven: 0, fiveReset: 1800, sevenReset: 86400),
                      candidate("invalid", fiveReset: 1800, invalid: true), candidate("future", age: -1, fiveReset: 1800)] {
            XCTAssertEqual(try XCTUnwrap(rank([value]).ranked.first).resetBonus, 0, value.account.id)
        }
    }

    func testUnknownPlanUsesTheSameTimePolicyWithoutInventingAMultiplier() {
        let result = rank([candidate("soon", plan: "Team", five: 80, fiveReset: 1800),
                           candidate("later", plan: "Team", five: 82, fiveReset: 14400)])
        XCTAssertEqual(result.ranked.first?.account.id, "soon")
        XCTAssertTrue(result.ranked.allSatisfy { $0.baseScore == nil && $0.score == nil })
        XCTAssertGreaterThan(result.ranked[0].resetBonus, result.ranked[1].resetBonus)
    }

    func testResetBonusDoesNotForceSwitchingAwayFromAHealthyHigherReserve() {
        let result = rank([candidate("active", five: 82, fiveReset: 14400, sevenReset: 6 * 86400),
                           candidate("soon", five: 80, fiveReset: 1800, sevenReset: 6 * 86400)], active: "active")
        XCTAssertEqual(result.ranked.first?.account.id, "soon")
        XCTAssertNil(result.advice)
    }

    func testReevaluatingTimeUpdatesBonusWithoutChangingTheReading() throws {
        let value = candidate("a", fiveReset: 14400)
        let earlier = try XCTUnwrap(rank([value]).ranked.first)
        let later = try XCTUnwrap(AccountRanking.evaluate([value], activeID: nil, now: now.addingTimeInterval(300)).ranked.first)
        XCTAssertGreaterThan(later.resetBonus, earlier.resetBonus)
        XCTAssertEqual(later.baseScore, earlier.baseScore)
        XCTAssertEqual(later.rows, earlier.rows)
        let stale = try XCTUnwrap(AccountRanking.evaluate([value], activeID: nil, now: now.addingTimeInterval(601)).ranked.first)
        XCTAssertEqual(stale.resetBonus, 0)
        XCTAssertEqual(stale.availability, .needsRefresh)
    }

    func testEqualScoresHaveStableOrderIndependentOfInputAndEmail() {
        var a = candidate("a"), b = candidate("b"), c = candidate("c")
        a.account.email = "zz•••zz@gmail.com"; b.account.email = "aa•••aa@outlook.com"; c.account.email = nil
        for input in [[a,b,c], [a,c,b], [b,a,c], [b,c,a], [c,a,b], [c,b,a]] {
            XCTAssertEqual(rank(input).ranked.map(\.account.id), ["a", "b", "c"])
        }
    }

    func testScoreIsMonotoneInBothWindowsAndBoundedByResetBonus() throws {
        for plan in ["Pro", "Max 5x", "Max 20x"] {
            let multiplier = try XCTUnwrap(AccountRanking.sessionMultiplier(plan: plan))
            for five in stride(from: 1.0, through: 99, by: 7) {
                for seven in stride(from: 1.0, through: 99, by: 7) {
                    let value = try XCTUnwrap(rank([candidate("a", plan: plan, five: five, seven: seven,
                                                              fiveReset: 1800, sevenReset: 86400)]).ranked.first)
                    let baseline = try XCTUnwrap(value.score)
                    let moreFive = try XCTUnwrap(rank([candidate("a", plan: plan, five: five+1, seven: seven,
                                                                 fiveReset: 1800, sevenReset: 86400)]).ranked.first?.score)
                    let moreSeven = try XCTUnwrap(rank([candidate("a", plan: plan, five: five, seven: seven+1,
                                                                  fiveReset: 1800, sevenReset: 86400)]).ranked.first?.score)
                    XCTAssertGreaterThanOrEqual(moreFive, baseline)
                    XCTAssertGreaterThanOrEqual(moreSeven, baseline)
                    XCTAssertLessThanOrEqual(baseline, multiplier*five/100*1.1+1e-9)
                    XCTAssertLessThanOrEqual(baseline, try XCTUnwrap(value.baseScore)*1.1+1e-9)
                    XCTAssertLessThanOrEqual(value.resetBonus, AccountRanking.maximumResetBonus)
                }
            }
        }
    }

    func testMenuFreezesPositionsAndWithdrawsChangedOrInvalidSuggestions() {
        let original = rank([candidate("active", five: 10), candidate("a", five: 70), candidate("b", five: 60)], active: "active")
        let menu = AccountMenuSnapshot(original)
        XCTAssertEqual(menu.suggestedID, "a")
        let changed = rank([candidate("active", five: 10), candidate("a", five: 40), candidate("b", five: 90)], active: "active")
        XCTAssertEqual(changed.advice?.accountID, "b")
        XCTAssertEqual(menu.accounts(from: changed).map(\.id), ["active", "a", "b"])
        XCTAssertNil(menu.advice(from: changed))
        let reopened = AccountMenuSnapshot(changed)
        XCTAssertEqual(reopened.accountIDs, ["active", "b", "a"])
        XCTAssertEqual(reopened.advice(from: changed)?.accountID, "b")
        let expired = rank([candidate("active", five: 10), candidate("a", invalid: true)], active: "active")
        XCTAssertNil(menu.advice(from: expired))
        let added = rank([candidate("active", five: 10), candidate("b", five: 60), candidate("new", five: 95)], active: "active")
        XCTAssertEqual(menu.accounts(from: added).map(\.id), ["active", "b", "new"])
    }
}
