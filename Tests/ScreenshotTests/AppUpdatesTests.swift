import XCTest
import SwitchCore
import SwitchMac
@testable import ClaudeSwitch

@MainActor
final class AppUpdatesTests: XCTestCase {
    private func storage() -> UserDefaults {
        let name = "ClaudeSwitchUpdateTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    func testDailyAutomaticChecksAndExplicitChecksRespectTheSwitch() async throws {
        let defaults = storage()
        var now = Date(timeIntervalSince1970: 1_800_000_000), reads = 0
        let updates = AppUpdates(demo: false, currentVersion: "0.1.5", defaults: defaults, now: { now }) {
            reads += 1; return ReleaseVersion("v0.1.6")!
        }
        await updates.check(manual: false)
        XCTAssertEqual(reads, 1); XCTAssertTrue(updates.hasUpdate)
        XCTAssertEqual(updates.status, .available)
        now.addTimeInterval(3600)
        await updates.check(manual: false)
        XCTAssertEqual(reads, 1)
        now.addTimeInterval(86400)
        updates.setAutomatic(false)
        await updates.check(manual: false)
        XCTAssertEqual(reads, 1)
        await updates.check(manual: true)
        XCTAssertEqual(reads, 2)
        let restarted = AppUpdates(demo: false, currentVersion: "0.1.5", defaults: defaults, now: { now }) {
            XCTFail("A restart must preserve the daily limit"); return ReleaseVersion("0.1.6")!
        }
        XCTAssertFalse(restarted.automatic); XCTAssertTrue(restarted.hasUpdate)
        restarted.setAutomatic(true)
        await restarted.check(manual: false)
    }
    func testEqualOlderAndUnknownVersionsAreNotReportedAsNew() async {
        for (current, latest, expected) in [("0.1.5", "0.1.5", AppUpdates.Status.current),
                                            ("0.2.0", "0.1.5", .current), ("unknown", "0.1.5", .unknownVersion)] {
            let updates = AppUpdates(demo: false, currentVersion: current, defaults: storage(), fetch: { ReleaseVersion(latest)! })
            await updates.check(manual: true)
            XCTAssertEqual(updates.status, expected)
            XCTAssertFalse(updates.hasUpdate)
        }
    }
    func testFailureIsNotUpToDateAndServerCooldownSurvivesRestart() async {
        let defaults = storage()
        var now = Date(timeIntervalSince1970: 1_800_000_000), reads = 0
        let updates = AppUpdates(demo: false, currentVersion: "0.1.5", defaults: defaults, now: { now }) {
            reads += 1; throw ReleaseCheckError(retryAfter: now.addingTimeInterval(7200))
        }
        await updates.check(manual: true)
        XCTAssertEqual(updates.status, .failed)
        now.addTimeInterval(3600)
        let restarted = AppUpdates(demo: false, currentVersion: "0.1.5", defaults: defaults, now: { now }) {
            reads += 1; return ReleaseVersion("0.1.5")!
        }
        await restarted.check(manual: true)
        XCTAssertEqual(restarted.status, .cooldown); XCTAssertEqual(reads, 1)
        now.addTimeInterval(4000)
        await restarted.check(manual: true)
        XCTAssertEqual(restarted.status, .current); XCTAssertEqual(reads, 2)
    }
    func testConcurrentChecksShareOneRequest() async throws {
        var continuation: CheckedContinuation<ReleaseVersion, Error>?, reads = 0
        let updates = AppUpdates(demo: false, currentVersion: "0.1.5", defaults: storage(), fetch: {
            reads += 1
            return try await withCheckedThrowingContinuation { continuation = $0 }
        })
        let first = Task { await updates.check(manual: true) }
        for _ in 0..<20 { if continuation != nil { break }; await Task.yield() }
        guard let pending = continuation else { first.cancel(); XCTFail("Request did not start"); return }
        await updates.check(manual: true)
        await updates.check(manual: false)
        XCTAssertEqual(reads, 1); XCTAssertTrue(updates.isChecking)
        pending.resume(returning: ReleaseVersion("0.1.10")!)
        await first.value
        XCTAssertTrue(updates.hasUpdate)
    }
    func testDemoNeverFetchesOrStartsAutomaticChecks() async {
        let updates = AppUpdates(demo: true, currentVersion: "0.1.5", fetch: {
            XCTFail("Demo must not contact GitHub"); return ReleaseVersion("0.1.6")!
        })
        updates.start()
        await updates.check(manual: true)
        await updates.check(manual: false)
        XCTAssertEqual(updates.status, .idle)
    }
    func testRapidManualChecksDoNotSendRepeatedRequests() async {
        var reads = 0
        let updates = AppUpdates(demo: false, currentVersion: "0.1.5", defaults: storage(), fetch: {
            reads += 1; return ReleaseVersion("0.1.5")!
        })
        await updates.check(manual: true)
        await updates.check(manual: true)
        XCTAssertEqual(reads, 1); XCTAssertEqual(updates.status, .current)
    }
}
