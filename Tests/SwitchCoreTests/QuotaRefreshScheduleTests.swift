import XCTest
@testable import SwitchCore

final class QuotaRefreshScheduleTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let a = "0a1b2c3d-1111-4aaa-8bbb-000000000001"
    private let b = "0a1b2c3d-2222-4aaa-8bbb-000000000002"
    private let org = "0a1b2c3d-3333-4aaa-8bbb-000000000003"
    private func snapshot(_ id: String, at date: Date) -> UsageSnapshot {
        .init(accountID: id, organizationID: org, observedAt: date, origin: .live,
              windows: [.init(id: "five_hour", title: "Session", usedPercent: 10)])
    }
    private func make() -> QuotaRefreshSchedule {
        var schedule = QuotaRefreshSchedule()
        schedule.activity = .init(running: true, online: true)
        schedule.synchronize(accounts: [a, b].map { Account(id: $0, organizationID: org, hasSnapshot: true) },
                             snapshots: [a: snapshot(a, at: base), b: snapshot(b, at: base)], now: base)
        schedule.selectCurrent(a, now: base)
        return schedule
    }
    func testSharedAccessRecoveryPreservesCredentialBlocksAndServerCooldowns() {
        var schedule = make()
        let later = base.addingTimeInterval(3600)
        schedule.suspend(a, awaitingAccess: true)
        schedule.deferRead(a, until: later.addingTimeInterval(60))
        schedule.suspend(b)
        XCTAssertEqual(schedule.resumeAfterAccess(), [a])
        XCTAssertFalse(schedule.isBlocked(a))
        XCTAssertTrue(schedule.isBlocked(b))
        XCTAssertTrue(schedule.dueAccounts(current: a, now: later).isEmpty)
        XCTAssertEqual(schedule.dueAccounts(current: a, now: later.addingTimeInterval(60)), [a])
        XCTAssertTrue(schedule.resumeAfterAccess().isEmpty)
    }
    func testAllAccessBlockedAccountsResumeOnceAndRemovedAccountsStayRemoved() {
        var schedule = make()
        schedule.suspend(a, awaitingAccess: true); schedule.suspend(b, awaitingAccess: true)
        XCTAssertEqual(Set(schedule.resumeAfterAccess()), Set([a, b]))
        schedule.suspend(a, awaitingAccess: true); schedule.suspend(b, awaitingAccess: true)
        schedule.synchronize(accounts: [Account(id: a, organizationID: org, hasSnapshot: true)], snapshots: [:], now: base)
        XCTAssertEqual(schedule.resumeAfterAccess(), [a])
        XCTAssertTrue(schedule.accountsAwaitingAccess.isEmpty)
    }
    func testChangeDensitySpeedsUpAndDecaysWithoutScalingBySessionCount() {
        var schedule = make()
        for minute in 0..<5 {
            let date = base.addingTimeInterval(Double(minute * 60))
            schedule.observeTaskChanges(accountID: a, changed: true, complete: true, at: date)
            // Duplicate callbacks in the same minute do not add samples.
            schedule.observeTaskChanges(accountID: a, changed: true, complete: true, at: date.addingTimeInterval(1))
            XCTAssertEqual(schedule.interval(for: a, current: a, now: date.addingTimeInterval(1)), [300, 120, 120, 60, 60][minute])
            XCTAssertEqual(schedule.interval(for: b, current: a, now: date), 1800)
        }
        for minute in 5...9 {
            let date = base.addingTimeInterval(Double(minute * 60))
            schedule.observeTaskChanges(accountID: a, changed: false, complete: true, at: date)
            XCTAssertEqual(schedule.interval(for: a, current: a, now: date), [60, 120, 120, 300, 900][minute - 5])
        }
    }
    func testQuietRequiresThirtyMinutesOfCompleteObservations() {
        var schedule = make()
        for minute in 0...30 {
            let date = base.addingTimeInterval(Double(minute * 60))
            schedule.observeTaskChanges(accountID: a, changed: false, complete: true, at: date)
            XCTAssertEqual(schedule.interval(for: a, current: a, now: date), minute == 30 ? 1800 : 900)
        }
        let later = base.addingTimeInterval(1860)
        schedule.observeTaskChanges(accountID: a, changed: false, complete: false, at: later)
        XCTAssertEqual(schedule.interval(for: a, current: a, now: later), 900)
        schedule.observeTaskChanges(accountID: a, changed: false, complete: true, at: later.addingTimeInterval(60))
        XCTAssertEqual(schedule.interval(for: a, current: a, now: later.addingTimeInterval(60)), 900)
    }
    func testUnknownOrStaleObservationNeverClaimsHighActivityOrQuiet() {
        var schedule = make()
        schedule.observeTaskChanges(accountID: a, changed: true, complete: false, at: base)
        XCTAssertEqual(schedule.interval(for: a, current: a, now: base), 900)
        schedule.observeTaskChanges(accountID: a, changed: true, complete: true, at: base)
        XCTAssertEqual(schedule.interval(for: a, current: a, now: base.addingTimeInterval(91)), 900)
    }
    func testSwitchClearsTheReturningAccountsActivityWindow() {
        var schedule = make()
        schedule.observeTaskChanges(accountID: a, changed: true, complete: true, at: base)
        schedule.selectCurrent(b, now: base)
        schedule.selectCurrent(a, now: base.addingTimeInterval(60))
        XCTAssertEqual(schedule.interval(for: a, current: a, now: base.addingTimeInterval(60)), 900)
    }
    func testDueTimeIsAnchoredToSuccessAndDoesNotSlideEveryTick() {
        var schedule = make()
        for minute in 1..<15 { XCTAssertTrue(schedule.dueAccounts(current: a, now: base.addingTimeInterval(Double(minute * 60))).isEmpty) }
        XCTAssertEqual(schedule.dueAccounts(current: a, now: base.addingTimeInterval(900)), [a])
        schedule.succeeded(snapshot(a, at: base.addingTimeInterval(900)))
        XCTAssertTrue(schedule.dueAccounts(current: a, now: base.addingTimeInterval(960)).isEmpty)
        XCTAssertTrue(schedule.dueAccounts(current: a, now: base.addingTimeInterval(1799)).isEmpty)
        XCTAssertEqual(schedule.dueAccounts(current: a, now: base.addingTimeInterval(1800)), [a, b])
    }
    func testStopOfflineSleepDisableAndCredentialBlockPreventPolling() {
        var schedule = make()
        let due = base.addingTimeInterval(3600)
        for activity in [QuotaRefreshSchedule.Activity(running: false, online: true), .init(running: true, online: false), .init(running: true, online: true, awake: false)] {
            schedule.activity = activity
            XCTAssertTrue(schedule.dueAccounts(current: a, now: due).isEmpty)
        }
        schedule.activity = .init(running: true, online: true)
        schedule.preferences.enabled = false
        XCTAssertTrue(schedule.dueAccounts(current: a, now: due).isEmpty)
        schedule.preferences.enabled = true
        schedule.suspend(a)
        XCTAssertEqual(schedule.dueAccounts(current: a, now: due), [b])
        schedule.deferRead(a, until: due.addingTimeInterval(300))
        schedule.credentialsChanged(a)
        XCTAssertEqual(schedule.dueAccounts(current: a, now: due), [b])
        XCTAssertEqual(schedule.dueAccounts(current: a, now: due.addingTimeInterval(300)), [a, b])
    }
    func testSettingsApplyImmediatelyAndLegacyPreferencesDecode() throws {
        var schedule = make()
        for i in 0..<5 { schedule.observeTaskChanges(accountID: a, changed: true, complete: true, at: base.addingTimeInterval(Double(i * 60))) }
        let date = base.addingTimeInterval(240)
        schedule.preferences.minimumMinutes = 2
        XCTAssertEqual(schedule.interval(for: a, current: a, now: date), 120)
        schedule.preferences.adaptive = false
        schedule.preferences.baselineMinutes = 30
        XCTAssertEqual(schedule.interval(for: a, current: a, now: date), 1800)
        let legacy = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.quotaRefresh, QuotaRefreshPreferences())
        let previous = try JSONDecoder().decode(QuotaRefreshPreferences.self, from: Data(#"{"baselineMinutes":15,"minimumMinutes":2}"#.utf8))
        XCTAssertEqual(previous.otherAccountsMinutes, 30)
        XCTAssertEqual(previous.baselineMinutes, 15)
        XCTAssertEqual(previous.minimumMinutes, 2)
        schedule.preferences.otherAccountsMinutes = 60
        XCTAssertEqual(schedule.interval(for: b, current: a, now: date), 3600)
        XCTAssertEqual(schedule.interval(for: a, current: a, now: date), 1800)
        var preferences = legacy
        preferences.quotaRefresh = schedule.preferences
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences)).quotaRefresh,
                       schedule.preferences.normalized)
    }
}
