import Foundation
import XCTest
@testable import SwitchCore

final class QuotaResetTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3600, day: TimeInterval = 86400

    private func snapshot(_ origin: UsageOrigin, at offset: TimeInterval, _ windows: [QuotaWindow]) -> UsageSnapshot {
        UsageSnapshot(accountID: "a", organizationID: "o", observedAt: base.addingTimeInterval(offset), origin: origin, windows: windows)
    }

    func testElapsedFiveHourWindowStartsEmptyWithUnknownReset() {
        let window = QuotaWindow(id: "five_hour", title: "5h", usedPercent: 80, resetsAt: base.addingTimeInterval(hour))
        XCTAssertEqual(window.rolledOver(now: base), window)
        let rolled = window.rolledOver(now: base.addingTimeInterval(hour))
        XCTAssertEqual(rolled.usedPercent, 0)
        XCTAssertNil(rolled.resetsAt)
    }

    func testElapsedWeeklyWindowKeepsItsSchedule() {
        let reset = base.addingTimeInterval(day)
        let window = QuotaWindow(id: "seven_day", title: "7d", usedPercent: 70, resetsAt: reset)
        XCTAssertEqual(window.rolledOver(now: reset.addingTimeInterval(1)).resetsAt, reset.addingTimeInterval(7 * day))
        XCTAssertEqual(window.rolledOver(now: reset.addingTimeInterval(15 * day)).resetsAt, reset.addingTimeInterval(21 * day))
        let model = QuotaWindow(id: "model:Opus", title: "Opus", usedPercent: 40, resetsAt: reset).rolledOver(now: reset)
        XCTAssertEqual(model.usedPercent, 0)
        XCTAssertNil(model.resetsAt)
    }

    func testUntouchedFiveHourWindowAwaitsFirstUse() {
        let live = snapshot(.live, at: 0, [QuotaWindow(id: "five_hour", title: "5h", usedPercent: 0),
                                           QuotaWindow(id: "seven_day", title: "7d", usedPercent: 0)])
        let fiveHour = QuotaReadout.make(id: "five_hour", title: "5h", window: live.windows[0], snapshot: live, active: true, now: base)
        let weekly = QuotaReadout.make(id: "seven_day", title: "7d", window: live.windows[1], snapshot: live, active: true, now: base)
        XCTAssertTrue(fiveHour.awaitingFirstUse)
        XCTAssertFalse(weekly.awaitingFirstUse)
        let started = snapshot(.live, at: 0, [QuotaWindow(id: "five_hour", title: "5h", usedPercent: 3, resetsAt: base.addingTimeInterval(hour))])
        XCTAssertFalse(QuotaReadout.make(id: "five_hour", title: "5h", window: started.windows[0], snapshot: started,
                                         active: true, now: base).awaitingFirstUse)
    }

    private func rows(fiveHour: Double, sevenDay: Double, at offset: TimeInterval = 0,
                      fiveReset: TimeInterval? = nil, sevenReset: TimeInterval? = nil) -> [QuotaReadout] {
        let live = snapshot(.live, at: offset, [
            QuotaWindow(id: "five_hour", title: "5h", usedPercent: 100 - fiveHour, resetsAt: base.addingTimeInterval(fiveReset ?? 2 * hour)),
            QuotaWindow(id: "seven_day", title: "7d", usedPercent: 100 - sevenDay, resetsAt: base.addingTimeInterval(sevenReset ?? 3 * day))])
        return live.windows.map { QuotaReadout.make(id: $0.id, title: $0.title, window: $0, snapshot: live, active: false, now: base) }
    }

    func testEvenRemainingFollowsTimeLeftInWindow() {
        let five = rows(fiveHour: 50, sevenDay: 50)[0]
        XCTAssertEqual(try XCTUnwrap(five.evenRemaining(now: base)), 40, accuracy: 0.001)
        XCTAssertNil(five.evenRemaining(now: base.addingTimeInterval(3 * hour)))
    }

    func testAdviceOnlyWhenActiveIsLowAndTargetIsClearlyBetter() {
        XCTAssertNil(SwitchAdvisor.advice(active: rows(fiveHour: 60, sevenDay: 50), candidates: [("b", rows(fiveHour: 100, sevenDay: 90))], now: base))
        let low = rows(fiveHour: 15, sevenDay: 50)
        XCTAssertNil(SwitchAdvisor.advice(active: low, candidates: [("b", rows(fiveHour: 30, sevenDay: 90))], now: base))
        XCTAssertNil(SwitchAdvisor.advice(active: low, candidates: [("b", rows(fiveHour: 90, sevenDay: 10))], now: base))
        let advice = SwitchAdvisor.advice(active: low, candidates: [("b", rows(fiveHour: 60, sevenDay: 90)),
                                                                    ("c", rows(fiveHour: 80, sevenDay: 30))], now: base)
        XCTAssertEqual(advice?.accountID, "c")
        XCTAssertEqual(advice?.reason, .fiveHourLow("15%"))
    }

    func testWeeklyShortageAdvisesEvenWithFullFiveHourWindow() {
        let advice = SwitchAdvisor.advice(active: rows(fiveHour: 100, sevenDay: 3), candidates: [("b", rows(fiveHour: 66, sevenDay: 29))], now: base)
        XCTAssertEqual(advice?.accountID, "b")
        XCTAssertEqual(advice?.reason, .sevenDayLow("3%"))
    }

    func testShortageThatResetsShortlyIsWaitedOut() {
        let candidate = [("b", rows(fiveHour: 90, sevenDay: 90))]
        XCTAssertNil(SwitchAdvisor.advice(active: rows(fiveHour: 10, sevenDay: 60, fiveReset: 20 * 60), candidates: candidate, now: base))
        XCTAssertNil(SwitchAdvisor.advice(active: rows(fiveHour: 80, sevenDay: 5, sevenReset: 40 * 60), candidates: candidate, now: base))
    }

    func testQuotaAboutToResetUnspentIsWorthUsing() {
        let healthy = rows(fiveHour: 80, sevenDay: 60)
        let weekly = SwitchAdvisor.advice(active: healthy, candidates: [("b", rows(fiveHour: 70, sevenDay: 40, sevenReset: 10 * hour)),
                                                                       ("c", rows(fiveHour: 90, sevenDay: 80))], now: base)
        XCTAssertEqual(weekly?.accountID, "b")
        XCTAssertEqual(weekly.map { if case .expiring(let row) = $0.reason { row.id } else { "" } }, "seven_day")
        let fiveHour = SwitchAdvisor.advice(active: healthy, candidates: [("b", rows(fiveHour: 75, sevenDay: 50, fiveReset: 40 * 60))], now: base)
        XCTAssertEqual(fiveHour.map { if case .expiring(let row) = $0.reason { row.id } else { "" } }, "five_hour")
        XCTAssertNil(SwitchAdvisor.advice(active: healthy, candidates: [("b", rows(fiveHour: 70, sevenDay: 10, sevenReset: 10 * hour))], now: base))
        let lapsing = rows(fiveHour: 80, sevenDay: 50, sevenReset: 5 * hour)
        XCTAssertNil(SwitchAdvisor.advice(active: lapsing, candidates: [("b", rows(fiveHour: 70, sevenDay: 40, sevenReset: 10 * hour))], now: base))
    }

    func testReadoutShowsFullQuotaOnceResetPasses() {
        let reset = base.addingTimeInterval(hour)
        let live = snapshot(.live, at: 0, [QuotaWindow(id: "seven_day", title: "7d", usedPercent: 90, resetsAt: reset)])
        let row = QuotaReadout.make(id: "seven_day", title: "7d", window: live.windows[0], snapshot: live,
                                    active: true, now: reset.addingTimeInterval(60))
        XCTAssertEqual(row.remainingPercent, 100)
        XCTAssertEqual(row.state, .recorded)
        XCTAssertEqual(row.resetsAt, reset.addingTimeInterval(7 * day))
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

    func testRolledWeeklyResetIsNotLentToAReadingFromThePreviousWindow() {
        let reset = base.addingTimeInterval(hour)
        let rolled = snapshot(.live, at: 0, [QuotaWindow(id: "seven_day", title: "7d", usedPercent: 60, resetsAt: reset)])
            .rollingOverElapsedResets(now: reset.addingTimeInterval(60))
        let late = snapshot(.localCache, at: 1800, [QuotaWindow(id: "seven_day", title: "7d", usedPercent: 65)])
        XCTAssertNil(late.retainingKnownResets(from: rolled).windows.first { $0.id == "seven_day" }?.resetsAt)
    }
}
