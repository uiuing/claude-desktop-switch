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
}
