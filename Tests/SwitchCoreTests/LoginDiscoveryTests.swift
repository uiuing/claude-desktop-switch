import XCTest
@testable import SwitchCore

@MainActor
final class LoginDiscoveryTests: XCTestCase {
    func testAlreadyPublishedLoginIsScannedImmediately() async {
        var scans = 0
        let discovery = LoginDiscovery(paused: { false }, signature: { "published" }) {
            scans += 1; return .saved
        }
        await discovery.poll()
        XCTAssertTrue(discovery.completed)
        await discovery.poll()
        XCTAssertEqual(scans, 1)
    }

    func testFailedScanRetriesWithoutAnotherPublication() async {
        var scans = 0
        let discovery = LoginDiscovery(paused: { false }, signature: { "unchanged" }) {
            scans += 1; return scans == 1 ? .retry : .saved
        }
        await discovery.poll()
        XCTAssertFalse(discovery.completed)
        await discovery.poll()
        XCTAssertTrue(discovery.completed)
        XCTAssertEqual(scans, 2)
    }

    func testPendingSaveIsRecheckedEvenIfFilesStopChanging() async {
        var now = Date(timeIntervalSince1970: 1_800_000_000), scans = 0
        let discovery = LoginDiscovery(now: { now }, paused: { false }, signature: { "stable" }) {
            scans += 1; return scans == 1 ? .pending : .saved
        }
        await discovery.poll()
        now.addTimeInterval(4); await discovery.poll()
        XCTAssertEqual(scans, 1)
        now.addTimeInterval(1); await discovery.poll()
        XCTAssertTrue(discovery.completed)
        XCTAssertEqual(scans, 2)
    }

    func testNewPublicationScansBeforeFallbackIsDue() async {
        var signature = "before", scans = 0
        let discovery = LoginDiscovery(paused: { false }, signature: { signature }) {
            scans += 1; return scans == 1 ? .pending : .saved
        }
        await discovery.poll()
        signature = "cookie-wal-published"
        await discovery.poll()
        XCTAssertTrue(discovery.completed)
        XCTAssertEqual(scans, 2)
    }

    func testBusyAndSleepingChecksDoNotConsumeThePublication() async {
        var paused = true, signatures = 0, scans = 0
        let discovery = LoginDiscovery(paused: { paused }, signature: {
            signatures += 1
            if signatures == 1 { paused = true }
            return "published"
        }) { scans += 1; return .saved }
        await discovery.poll()
        XCTAssertEqual(signatures, 0)
        paused = false; await discovery.poll()
        XCTAssertEqual(scans, 0)
        paused = false; await discovery.poll()
        XCTAssertTrue(discovery.completed)
        XCTAssertEqual(scans, 1)
    }

    func testLateLoginStillRecoversAfterTheFastWindow() async {
        var now = Date(timeIntervalSince1970: 1_800_000_000), signedIn = false
        let discovery = LoginDiscovery(now: { now }, paused: { false }, signature: { "unchanged" }) {
            signedIn ? .saved : .pending
        }
        XCTAssertEqual(discovery.pollingInterval, 1)
        await discovery.poll()
        now.addTimeInterval(901)
        XCTAssertEqual(discovery.pollingInterval, 5)
        await discovery.poll()
        signedIn = true
        now.addTimeInterval(15); await discovery.poll()
        XCTAssertTrue(discovery.completed)
    }

    func testWakeRestartsFastChecksAndRechecksUnchangedState() async {
        var now = Date(timeIntervalSince1970: 1_800_000_000), ready = false
        let discovery = LoginDiscovery(now: { now }, paused: { false }, signature: { "unchanged" }) {
            ready ? .saved : .pending
        }
        await discovery.poll()
        now.addTimeInterval(901); await discovery.poll()
        ready = true; discovery.resume()
        XCTAssertEqual(discovery.pollingInterval, 1)
        await discovery.poll()
        XCTAssertTrue(discovery.completed)
    }

    func testCanceledScanCannotCompleteAnAbandonedWatch() async {
        let discovery = LoginDiscovery(paused: { false }, signature: { "published" }) {
            withUnsafeCurrentTask { $0?.cancel() }
            return .saved
        }
        await Task { await discovery.poll() }.value
        XCTAssertFalse(discovery.completed)
        await discovery.poll()
        XCTAssertFalse(discovery.completed)
    }

    func testTransientSaveFailuresRemainRecoverableAfterShortRetries() {
        var now = Date(timeIntervalSince1970: 1_800_000_000), retry = LoginSaveRetry()
        for delay: TimeInterval in [1, 2, 5, 15, 30, 30, 30] {
            XCTAssertTrue(retry.shouldAttempt("same-credentials", now: now))
            XCTAssertEqual(retry.failed(transient: true, now: now), delay)
            XCTAssertFalse(retry.shouldAttempt("same-credentials", now: now))
            now.addTimeInterval(delay)
        }
        XCTAssertTrue(retry.showError)
        XCTAssertTrue(retry.shouldAttempt("same-credentials", now: now))
        retry.reset()
        XCTAssertFalse(retry.showError)
    }

    func testSleepDuringScanLeavesTheLoginAvailableForRecovery() async {
        var paused = false, scans = 0
        let discovery = LoginDiscovery(paused: { paused }, signature: { "published" }) {
            scans += 1
            if scans == 1 { paused = true }
            return .saved
        }
        await discovery.poll()
        XCTAssertFalse(discovery.completed)
        paused = false
        await discovery.poll()
        XCTAssertTrue(discovery.completed)
        XCTAssertEqual(scans, 2)
    }

    func testUnsupportedSaveWaitsForManualRetryOrNewCredentials() {
        var now = Date(timeIntervalSince1970: 1_800_000_000), retry = LoginSaveRetry()
        XCTAssertTrue(retry.shouldAttempt("original", now: now))
        XCTAssertNil(retry.failed(transient: false, now: now))
        XCTAssertTrue(retry.showError)
        now.addTimeInterval(3600)
        XCTAssertFalse(retry.shouldAttempt("original", now: now))
        XCTAssertTrue(retry.shouldAttempt("original", manual: true, now: now))
        XCTAssertFalse(retry.showError)
        _ = retry.failed(transient: false, now: now)
        XCTAssertTrue(retry.shouldAttempt("renewed", now: now))
        XCTAssertFalse(retry.showError)
    }

    func testOverlappingTicksShareOneScan() async {
        let entered = expectation(description: "Scan started")
        var finish: CheckedContinuation<LoginDiscovery.ScanResult, Never>?, scans = 0
        let discovery = LoginDiscovery(paused: { false }, signature: { "published" }) {
            scans += 1
            return await withCheckedContinuation { finish = $0; entered.fulfill() }
        }
        let first = Task { await discovery.poll() }
        await fulfillment(of: [entered], timeout: 2)
        await discovery.poll()
        XCTAssertEqual(scans, 1)
        finish?.resume(returning: .saved)
        await first.value
        XCTAssertTrue(discovery.completed)
    }
}
