import XCTest
import SwitchCore
@testable import ClaudeSwitch

@MainActor
final class QuotaPresentationTests: XCTestCase {
    func testFreshTimestampNeverSaysZeroSecondsInTheFuture() {
        let previous = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        defer { UserDefaults.standard.setVolatileDomain(previous, forName: UserDefaults.registrationDomain) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for language in AppLanguage.allCases {
            UserDefaults.standard.register(defaults: [L10n.preferenceKey: language.rawValue])
            for offset in [0.0, 0.5, 30, -0.5] {
                XCTAssertEqual(Format.age(now.addingTimeInterval(offset), now: now), L10n.tr("Just now"))
            }
        }
    }
    func testQuotaSubtitleShowsOnlyTheUpdateTime() throws {
        let state = AppState(demo: true)
        let id = try XCTUnwrap(state.activeID)
        let now = Date()
        state.library.usage[id]?.observedAt = now
        XCTAssertEqual(state.quotaUpdated(for: id, now: now), L10n.tr("Updated {0}", L10n.tr("Just now")))
        state.library.usage[id]?.observedAt = now.addingTimeInterval(120)
        XCTAssertEqual(state.quotaUpdated(for: id, now: now), L10n.tr("Update time unknown"))
    }

    func testSavedAndKnownAccountListsShareTheRecommendationOrder() throws {
        let state = AppState(demo: true)
        let ranking = state.accountRanking()
        XCTAssertEqual(state.accounts.map(\.id), ranking.displayAccounts.map(\.id))
        XCTAssertEqual(state.knownAccounts.filter(\.hasSnapshot).map(\.id), state.accounts.map(\.id))
        XCTAssertEqual(state.accounts.first?.id, state.activeID)
        let backup = try XCTUnwrap(ranking.bestBackup)
        XCTAssertEqual(state.accounts.dropFirst().first?.id, backup.account.id)
        XCTAssertEqual(state.switchAdvice()?.account.id, backup.account.id)
        XCTAssertEqual(backup.account.plan, "Max 5x")
    }

    func testRankingRejectsQuotaFromAnotherOrganization() throws {
        let state = AppState(demo: true)
        let backup = try XCTUnwrap(state.accountRanking().bestBackup?.account.id)
        state.library.usage[backup]?.organizationID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
        XCTAssertEqual(state.accountRanking().ranked.first { $0.account.id == backup }?.availability, .needsRefresh)
        XCTAssertNotEqual(state.switchAdvice()?.account.id, backup)
    }

    func testAllQuotaSurfacesRejectUnownedReadings() throws {
        for mismatch in ["account", "organization", "missingOrganization"] {
            let state = AppState(demo: true)
            let id = try XCTUnwrap(state.activeID)
            XCTAssertFalse(state.extraQuotaRows(for: id, now: Date()).isEmpty)
            if mismatch == "account" { state.library.usage[id]?.accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee" }
            if mismatch == "organization" { state.library.usage[id]?.organizationID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee" }
            if mismatch == "missingOrganization" { state.library.usage[id]?.organizationID = nil }
            XCTAssertNil(state.currentUsage, mismatch)
            XCTAssertTrue(state.quotaRows(for: id).allSatisfy { $0.state == .unknown && $0.percentageText == "—" }, mismatch)
            XCTAssertTrue(state.extraQuotaRows(for: id, now: Date()).isEmpty, mismatch)
            XCTAssertEqual(state.quotaUpdated(for: id), L10n.tr("No quota data yet"), mismatch)
            XCTAssertNil(state.switchAdvice(), mismatch)
        }
    }

    func testCachedReadingsKeepDisplayedQuotaAndResetTimes() throws {
        let previous = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        defer { UserDefaults.standard.setVolatileDomain(previous, forName: UserDefaults.registrationDomain) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(1800)
        for language in ["en", "de", "zh-Hans"] {
            UserDefaults.standard.register(defaults: [L10n.preferenceKey: language])
            let window = QuotaWindow(id: "five_hour", title: "Session", usedPercent: 27, resetsAt: reset)
            func row(age: TimeInterval, at date: Date = now) -> QuotaReadout {
                let snapshot = UsageSnapshot(accountID: "a", observedAt: now.addingTimeInterval(-age), origin: .live, windows: [window])
                return QuotaReadout.make(id: window.id, title: window.title, window: snapshot.windows[0], snapshot: snapshot, active: true, now: date)
            }
            let fresh = row(age: 0), stale = row(age: 10800), pending = row(age: 10800, at: reset)
            XCTAssertEqual(stale.percentageText, fresh.percentageText)
            XCTAssertEqual(pending.percentageText, fresh.percentageText)
            XCTAssertEqual(stale.lastRecordedPercentageText, fresh.percentageText)
            for showTime in [true, false] {
                XCTAssertEqual(Format.reset(stale, now: now, showResetTime: showTime), Format.reset(fresh, now: now, showResetTime: showTime))
                XCTAssertEqual(Format.tinyReset(stale, now: now, showResetTime: showTime), Format.tinyReset(fresh, now: now, showResetTime: showTime))
                XCTAssertEqual(Format.shortReset(stale, now: now, showResetTime: showTime), Format.shortReset(fresh, now: now, showResetTime: showTime))
            }
            let detail = try XCTUnwrap(Format.resetDetail(stale))
            XCTAssertTrue(detail.contains(Format.date(reset)))
            XCTAssertTrue(detail.contains(Format.date(now.addingTimeInterval(-10800))))
            XCTAssertTrue(detail.contains(L10n.tr("Last recorded: {0}", fresh.percentageText)))
            XCTAssertEqual(Format.reset(pending, now: reset), L10n.tr("{0} · Awaiting sync", Format.shortReset(pending, now: reset)))
            XCTAssertEqual(Format.reset(pending, now: reset, showResetTime: false), L10n.tr("Reset passed · Awaiting sync"))
            XCTAssertNotEqual(Format.tinyReset(pending, now: reset), L10n.tr("quota.pending"))
            XCTAssertTrue(try XCTUnwrap(Format.resetDetail(pending)).contains(Format.date(reset)))
        }
    }

    func testConfirmedNextUseTextSurvivesCacheAge() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let window = QuotaWindow(id: "five_hour", title: "Session", usedPercent: 0, resetKnownAbsent: true)
        let snapshot = UsageSnapshot(accountID: "a", observedAt: now.addingTimeInterval(-10800), origin: .live, windows: [window])
        let row = QuotaReadout.make(id: window.id, title: window.title, window: snapshot.windows[0], snapshot: snapshot, active: false, now: now)
        XCTAssertEqual(Format.reset(row, now: now), L10n.tr("Starts on next use"))
        XCTAssertEqual(Format.reset(row, now: now, showResetTime: false), L10n.tr("Starts on next use"))
        XCTAssertEqual(Format.tinyReset(row, now: now), L10n.tr("quota.notStarted"))
        XCTAssertEqual(Format.shortReset(row, now: now), L10n.tr("Not started"))
    }

    func testPausingAndResumingRefreshPreservesCachedAccountDetails() throws {
        let state = AppState(demo: true), now = Date()
        for account in state.library.accounts {
            state.library.usage[account.id]?.observedAt = now.addingTimeInterval(-10800)
            for index in state.library.usage[account.id]?.windows.indices ?? 0..<0 {
                state.library.usage[account.id]?.windows[index].observedAt = now.addingTimeInterval(-10800)
            }
        }
        let snapshots = state.library.usage, accounts = state.accounts
        for pause: QuotaRefreshSchedule.PauseReason? in [.claudeClosed, .offline, nil] {
            state.quotaRefreshPause = pause
            for account in accounts {
                let snapshot = try XCTUnwrap(snapshots[account.id])
                let rows = state.quotaRows(for: account.id, now: now)
                for row in rows {
                    let original = try XCTUnwrap(snapshot.windows.first { $0.id == row.id })
                    XCTAssertEqual(row.remainingPercent, 100 - original.usedPercent)
                    XCTAssertNotEqual(row.percentageText, "—")
                    XCTAssertEqual(row.resetsAt, original.resetsAt)
                }
                XCTAssertEqual(state.quotaUpdated(for: account.id, now: now), L10n.tr("Updated {0}", Format.age(snapshot.observedAt, now: now)))
                XCTAssertEqual(state.accounts.first { $0.id == account.id }?.email, account.email)
                XCTAssertEqual(state.accounts.first { $0.id == account.id }?.plan, account.plan)
            }
            XCTAssertNil(state.switchAdvice(now: now))
            XCTAssertEqual(state.library.usage, snapshots)
        }
    }
}
