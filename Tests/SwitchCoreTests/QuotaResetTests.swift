import Foundation
import XCTest
@testable import SwitchCore

final class QuotaResetTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3600, day: TimeInterval = 86400

    private func snapshot(_ origin: UsageOrigin, at offset: TimeInterval, _ windows: [QuotaWindow]) -> UsageSnapshot {
        UsageSnapshot(accountID: "a", organizationID: "o", observedAt: base.addingTimeInterval(offset), origin: origin, windows: windows)
    }

    func testElapsedFiveHourWindowPreservesMeasurement() {
        let window = QuotaWindow(id: "five_hour", title: "5h", usedPercent: 80, resetsAt: base.addingTimeInterval(hour))
        XCTAssertEqual(window.rolledOver(now: base), window)
        let rolled = window.rolledOver(now: base.addingTimeInterval(hour))
        XCTAssertEqual(rolled.usedPercent, 80)
        XCTAssertEqual(rolled.resetsAt, window.resetsAt)
    }

    func testElapsedWeeklyWindowDoesNotInventNewSchedule() {
        let reset = base.addingTimeInterval(day)
        let window = QuotaWindow(id: "seven_day", title: "7d", usedPercent: 70, resetsAt: reset)
        XCTAssertEqual(window.rolledOver(now: reset.addingTimeInterval(1)).resetsAt, reset)
        XCTAssertEqual(window.rolledOver(now: reset.addingTimeInterval(15 * day)).resetsAt, reset)
        let model = QuotaWindow(id: "model:Opus", title: "Opus", usedPercent: 40, resetsAt: reset).rolledOver(now: reset)
        XCTAssertEqual(model.usedPercent, 40)
        XCTAssertEqual(model.resetsAt, reset)
    }

    func testUntouchedFiveHourWindowAwaitsFirstUse() {
        let live = snapshot(.live, at: 0, [QuotaWindow(id: "five_hour", title: "5h", usedPercent: 0, resetKnownAbsent: true),
                                           QuotaWindow(id: "seven_day", title: "7d", usedPercent: 0)])
        let fiveHour = QuotaReadout.make(id: "five_hour", title: "5h", window: live.windows[0], snapshot: live, active: true, now: base)
        let weekly = QuotaReadout.make(id: "seven_day", title: "7d", window: live.windows[1], snapshot: live, active: true, now: base)
        XCTAssertTrue(fiveHour.awaitingFirstUse)
        XCTAssertFalse(weekly.awaitingFirstUse)
        let started = snapshot(.live, at: 0, [QuotaWindow(id: "five_hour", title: "5h", usedPercent: 3, resetsAt: base.addingTimeInterval(hour))])
        XCTAssertFalse(QuotaReadout.make(id: "five_hour", title: "5h", window: started.windows[0], snapshot: started,
                                         active: true, now: base).awaitingFirstUse)
    }

    func testLastMeasurementRemainsVisibleAcrossFreshnessAndResetBoundaries() throws {
        let reset = base.addingTimeInterval(4 * hour)
        let original = snapshot(.live, at: 0, [QuotaWindow(id: "five_hour", title: "Session", usedPercent: 27, resetsAt: reset)])
        func row(at date: Date) -> QuotaReadout {
            QuotaReadout.make(id: "five_hour", title: "Session", window: original.windows[0], snapshot: original, active: false, now: date)
        }
        let fresh = row(at: base), stale = row(at: base.addingTimeInterval(3 * hour)), pending = row(at: reset)
        XCTAssertEqual(fresh.currentRemainingPercent, 73)
        XCTAssertNil(fresh.lastRecordedPercentageText)
        XCTAssertEqual(stale.remainingPercent, 73)
        XCTAssertNil(stale.currentRemainingPercent)
        XCTAssertEqual(stale.percentageText, fresh.percentageText)
        XCTAssertEqual(stale.lastRecordedPercentageText, fresh.percentageText)
        XCTAssertEqual(stale.resetsAt, reset)
        XCTAssertEqual(stale.observedAt, base)
        XCTAssertNil(stale.evenRemaining(now: base.addingTimeInterval(3 * hour)))
        XCTAssertEqual(pending.state, .resetPending)
        XCTAssertNil(pending.currentRemainingPercent)
        XCTAssertEqual(pending.remainingPercent, fresh.remainingPercent)
        XCTAssertEqual(pending.percentageText, fresh.percentageText)
        XCTAssertEqual(pending.lastRecordedPercentageText, fresh.percentageText)
        XCTAssertEqual(pending.resetsAt, reset)
        XCTAssertEqual(original.windows[0].usedPercent, 27)
        XCTAssertEqual(original.observedAt, base)
    }

    func testConfirmedUnusedSessionRemainsVisibleInOldCache() {
        let live = snapshot(.live, at: 0, [QuotaWindow(id: "five_hour", title: "Session", usedPercent: 0, resetKnownAbsent: true)])
        let stale = QuotaReadout.make(id: "five_hour", title: "Session", window: live.windows[0], snapshot: live,
                                     active: false, now: base.addingTimeInterval(3 * hour))
        XCTAssertEqual(stale.state, .stale)
        XCTAssertEqual(stale.remainingPercent, 100)
        XCTAssertTrue(stale.awaitingFirstUse)
        XCTAssertFalse(AccountRanking.recent(stale, now: base.addingTimeInterval(3 * hour)))
        XCTAssertNil(stale.currentRemainingPercent)
        var unknownReset = live.windows[0]
        unknownReset.resetKnownAbsent = nil
        XCTAssertFalse(QuotaReadout.make(id: "five_hour", title: "Session", window: unknownReset, snapshot: live,
                                        active: false, now: base.addingTimeInterval(3 * hour)).awaitingFirstUse)
    }

    func testExpiredReadingNeverBecomesAFullQuotaOrSwitchRecommendation() {
        let past = rows(fiveHour: 12, sevenDay: 64, at: -3600, fiveReset: -60)
        XCTAssertEqual(past[0].state, .resetPending)
        XCTAssertEqual(past[0].remainingPercent, 12)
        XCTAssertFalse(past[0].awaitingFirstUse)
        XCTAssertNil(recommend(active: rows(fiveHour: 5, sevenDay: 50), candidates: [("b", past)], now: base))
        XCTAssertNil(recommend(active: past, candidates: [("b", rows(fiveHour: 90, sevenDay: 90))], now: base))
    }

    private func rows(fiveHour: Double, sevenDay: Double, at offset: TimeInterval = 0,
                      fiveReset: TimeInterval? = nil, sevenReset: TimeInterval? = nil) -> [QuotaReadout] {
        let live = snapshot(.live, at: offset, [
            QuotaWindow(id: "five_hour", title: "5h", usedPercent: 100 - fiveHour, resetsAt: base.addingTimeInterval(fiveReset ?? 2 * hour)),
            QuotaWindow(id: "seven_day", title: "7d", usedPercent: 100 - sevenDay, resetsAt: base.addingTimeInterval(sevenReset ?? 3 * day))])
        return live.windows.map { QuotaReadout.make(id: $0.id, title: $0.title, window: $0, snapshot: live, active: false, now: base) }
    }

    private func recommend(active: [QuotaReadout], candidates: [(id: String, rows: [QuotaReadout])], now: Date) -> SwitchAdvice? {
        func account(_ id: String) -> Account {
            var value = Account(id: id, hasSnapshot: true)
            value.plan = "Pro"
            return value
        }
        return AccountRanking.evaluate([(account("active"), active)] + candidates.map { (account($0.id), $0.rows) },
                                       activeID: "active", now: now).advice
    }

    func testEvenRemainingFollowsTimeLeftInWindow() {
        let five = rows(fiveHour: 50, sevenDay: 50)[0]
        XCTAssertEqual(try XCTUnwrap(five.evenRemaining(now: base)), 40, accuracy: 0.001)
        XCTAssertNil(five.evenRemaining(now: base.addingTimeInterval(3 * hour)))
    }

    func testAdviceOnlyWhenActiveIsLowAndTargetIsClearlyBetter() {
        XCTAssertNil(recommend(active: rows(fiveHour: 60, sevenDay: 50), candidates: [("b", rows(fiveHour: 100, sevenDay: 90))], now: base))
        let low = rows(fiveHour: 10, sevenDay: 50)
        XCTAssertNil(recommend(active: low, candidates: [("b", rows(fiveHour: 25, sevenDay: 90))], now: base))
        XCTAssertNil(recommend(active: low, candidates: [("b", rows(fiveHour: 90, sevenDay: 10))], now: base))
        let advice = recommend(active: low, candidates: [("b", rows(fiveHour: 60, sevenDay: 90)),
                                                                    ("c", rows(fiveHour: 80, sevenDay: 30))], now: base)
        XCTAssertEqual(advice?.accountID, "c")
        XCTAssertEqual(advice?.reason, .fiveHourLow("10%"))
    }

    func testWeeklyShortageAdvisesEvenWithFullFiveHourWindow() {
        let advice = recommend(active: rows(fiveHour: 100, sevenDay: 3), candidates: [("b", rows(fiveHour: 66, sevenDay: 29))], now: base)
        XCTAssertEqual(advice?.accountID, "b")
        XCTAssertEqual(advice?.reason, .sevenDayLow("3%"))
    }

    func testShortageThatResetsShortlyIsWaitedOut() {
        let candidate = [("b", rows(fiveHour: 90, sevenDay: 90))]
        XCTAssertNil(recommend(active: rows(fiveHour: 10, sevenDay: 60, fiveReset: 20 * 60), candidates: candidate, now: base))
        XCTAssertNil(recommend(active: rows(fiveHour: 80, sevenDay: 5, sevenReset: 40 * 60), candidates: candidate, now: base))
    }

    func testExpiryNeverOverridesTheBestBackupOrReducesHeadroom() {
        let healthy = rows(fiveHour: 80, sevenDay: 60)
        let weekly = recommend(active: healthy, candidates: [("b", rows(fiveHour: 70, sevenDay: 40, sevenReset: 10 * hour)),
                                                             ("c", rows(fiveHour: 90, sevenDay: 80))], now: base)
        XCTAssertNil(weekly)
        let fiveHour = recommend(active: healthy, candidates: [("b", rows(fiveHour: 85, sevenDay: 65, fiveReset: 40 * 60))], now: base)
        XCTAssertEqual(fiveHour.map { if case .expiring(let row) = $0.reason { row.id } else { "" } }, "five_hour")
        XCTAssertNil(recommend(active: healthy, candidates: [("b", rows(fiveHour: 75, sevenDay: 50, fiveReset: 40 * 60))], now: base))
        XCTAssertNil(recommend(active: healthy, candidates: [("b", rows(fiveHour: 90, sevenDay: 70, fiveReset: 60))], now: base))
        let lapsing = rows(fiveHour: 80, sevenDay: 50, sevenReset: 5 * hour)
        XCTAssertNil(recommend(active: lapsing, candidates: [("b", rows(fiveHour: 85, sevenDay: 60, sevenReset: 10 * hour))], now: base))
    }

    func testReadoutWaitsForConfirmationOnceResetPasses() {
        let reset = base.addingTimeInterval(hour)
        let live = snapshot(.live, at: 0, [QuotaWindow(id: "seven_day", title: "7d", usedPercent: 90, resetsAt: reset)])
        let row = QuotaReadout.make(id: "seven_day", title: "7d", window: live.windows[0], snapshot: live,
                                    active: true, now: reset.addingTimeInterval(60))
        XCTAssertEqual(row.remainingPercent, 10)
        XCTAssertNil(row.currentRemainingPercent)
        XCTAssertEqual(row.state, .resetPending)
        XCTAssertEqual(row.resetsAt, reset)
    }

    func testLocalReadingKeepsServerResetInsideTheSameWindow() {
        let reset = base.addingTimeInterval(2 * hour)
        let live = snapshot(.live, at: 0, [QuotaWindow(id: "five_hour", title: "5h", usedPercent: 20, resetsAt: reset),
                                           QuotaWindow(id: "seven_day_opus", title: "Opus", usedPercent: 5, resetsAt: reset)])
        let local = snapshot(.localCache, at: 300, [QuotaWindow(id: "five_hour", title: "5h", usedPercent: 25)])
        let merged = local.retainingKnownResets(from: live)
        XCTAssertEqual(merged.windows.first { $0.id == "five_hour" }?.resetsAt, reset)
        XCTAssertEqual(merged.windows.first { $0.id == "five_hour" }?.usedPercent, 25)
        XCTAssertEqual(merged.windows.first { $0.id == "seven_day_opus" }?.usedPercent, 5)
    }

    func testElapsedPresentationDoesNotMutateMeasurementUsedForMerging() {
        let reset = base.addingTimeInterval(hour)
        let rolled = snapshot(.live, at: 0, [QuotaWindow(id: "seven_day", title: "7d", usedPercent: 60, resetsAt: reset)])
            .rollingOverElapsedResets(now: reset.addingTimeInterval(60))
        let late = snapshot(.localCache, at: 1800, [QuotaWindow(id: "seven_day", title: "7d", usedPercent: 65)])
        XCTAssertEqual(late.retainingKnownResets(from: rolled).windows.first { $0.id == "seven_day" }?.resetsAt, reset)
    }

    func testRetainedWindowsAndResetKeepTheirOwnProvenance() throws {
        let live = snapshot(.live, at: 0, [
            QuotaWindow(id: "five_hour", title: "Session", usedPercent: 20, resetsAt: base.addingTimeInterval(2 * hour)),
            QuotaWindow(id: "seven_day_opus", title: "Opus", usedPercent: 5)])
        let local = snapshot(.localCache, at: 900, [QuotaWindow(id: "five_hour", title: "Session", usedPercent: 25)])
        let merged = local.retainingKnownResets(from: live)
        let five = try XCTUnwrap(merged.windows.first { $0.id == "five_hour" })
        XCTAssertEqual(five.observedAt, base.addingTimeInterval(900))
        XCTAssertEqual(five.origin, .localCache)
        XCTAssertEqual(five.resetObservedAt, base); XCTAssertEqual(five.resetOrigin, .live)
        let opus = try XCTUnwrap(merged.windows.first { $0.id == "seven_day_opus" })
        XCTAssertEqual(opus.observedAt, base); XCTAssertEqual(opus.origin, .live)
        let row = QuotaReadout.make(id: opus.id, title: opus.title, window: opus, snapshot: merged, active: true, now: base.addingTimeInterval(1000))
        XCTAssertEqual(row.state, .stale); XCTAssertEqual(row.remainingPercent, 95)
    }

    func testStaleQuotaCannotRecommendSwitching() {
        let low = rows(fiveHour: 10, sevenDay: 40)
        let stale = rows(fiveHour: 95, sevenDay: 90, at: -601)
        XCTAssertNil(recommend(active: low, candidates: [("b", stale)], now: base))
    }

    func testLegacySnapshotDecodesWithoutPerWindowMetadata() throws {
        let data = Data(#"{"accountID":"a","observedAt":0,"origin":"live","windows":[{"id":"five_hour","title":"Session","usedPercent":40,"resetIsEstimate":false}]}"#.utf8)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        XCTAssertNil(decoded.windows.first?.observedAt)
        let row = AccountQuotaPresentation.rows(accountID: "a", snapshot: decoded, active: true, now: decoded.observedAt)[0]
        XCTAssertEqual(row.remainingPercent, 60)
        XCTAssertEqual(row.observedAt, decoded.observedAt)
    }
}
