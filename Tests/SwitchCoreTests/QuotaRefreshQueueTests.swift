import XCTest
@testable import SwitchCore

@MainActor
final class QuotaRefreshQueueTests: XCTestCase {
    private let accountA = "0a1b2c3d-1111-4aaa-8bbb-000000000001"
    private let accountB = "0a1b2c3d-2222-4aaa-8bbb-000000000002"
    private let accountC = "0a1b2c3d-3333-4aaa-8bbb-000000000003"

    private func drainTasks() async {
        for _ in 0..<30 { await Task.yield() }
    }

    func testAccountsAreStaggeredAndPauseDoesNotCatchUpMissedTicks() async {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var reads: [String] = []
        let queue = QuotaRefreshQueue(now: { now }) { reads.append($0.accountID); return nil }
        queue.isPaused = true
        queue.observedAccount(accountA)
        for id in [accountB, accountC, accountA] { queue.enqueuePeriodic(id) }
        queue.isPaused = false
        await drainTasks()
        XCTAssertEqual(reads, [accountA])
        now.addTimeInterval(14); queue.isPaused = false
        await drainTasks()
        XCTAssertEqual(reads, [accountA])
        now.addTimeInterval(1); queue.isPaused = false
        await drainTasks()
        XCTAssertEqual(reads, [accountA, accountB])
        queue.isPaused = true
        now.addTimeInterval(3600)
        queue.enqueuePeriodic(accountC)
        await drainTasks()
        XCTAssertEqual(reads, [accountA, accountB])
        queue.isPaused = false
        await drainTasks()
        XCTAssertEqual(reads, [accountA, accountB, accountC])
        queue.isPaused = true
    }

    func testManualSuccessSatisfiesPendingReadAndSpacesOtherAccounts() async {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var reads: [String] = []
        let queue = QuotaRefreshQueue(now: { now }) { reads.append($0.accountID); return nil }
        queue.isPaused = true
        queue.enqueuePeriodic(accountA); queue.enqueuePeriodic(accountB)
        queue.completedManualRead(accountID: accountA, succeeded: true)
        queue.isPaused = false
        await drainTasks()
        XCTAssertTrue(reads.isEmpty)
        now.addTimeInterval(15); queue.isPaused = false
        await drainTasks()
        XCTAssertEqual(reads, [accountB])
        queue.isPaused = true
    }

    func testRepeatedCurrentRequestsDoNotStarveOverdueAccounts() async {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var reads: [String] = []
        let queue = QuotaRefreshQueue(now: { now }) { reads.append($0.accountID); return nil }
        queue.isPaused = true
        queue.observedAccount(accountA)
        for id in [accountA, accountB, accountC] { queue.enqueuePeriodic(id) }
        queue.isPaused = false
        await drainTasks()
        XCTAssertEqual(reads, [accountA])
        queue.enqueueCurrent(accountA, reason: .reset)
        now.addTimeInterval(60); queue.isPaused = false
        await drainTasks()
        XCTAssertEqual(reads, [accountA, accountB])
        now.addTimeInterval(15); queue.isPaused = false
        await drainTasks()
        XCTAssertEqual(reads, [accountA, accountB, accountA])
        now.addTimeInterval(15); queue.isPaused = false
        await drainTasks()
        XCTAssertEqual(reads, [accountA, accountB, accountA, accountC])
        queue.isPaused = true
    }

    func testSuccessfulSwitchRefreshesBothAccountsOnlyOnce() async {
        var reads: [String] = []
        let queue = QuotaRefreshQueue(minimumSpacing: 0) { reads.append($0.accountID); return nil }
        queue.isPaused = true
        queue.observedAccount(accountA)
        queue.switched(from: accountA, to: accountB)
        queue.observedAccount(accountB)
        queue.enqueue(accountB)
        queue.isPaused = false
        await drainTasks()
        XCTAssertEqual(reads, [accountB, accountA])
        queue.isPaused = true
    }

    func testObservedSwitchRefreshesBothButInitialScanDoesNot() async {
        var reads: [String] = []
        let queue = QuotaRefreshQueue(minimumSpacing: 0) { reads.append($0.accountID); return nil }
        queue.observedAccount(accountA)
        await drainTasks()
        XCTAssertTrue(reads.isEmpty)
        queue.observedAccount(accountB)
        await drainTasks()
        XCTAssertEqual(reads, [accountB, accountA])
        queue.isPaused = true
    }

    func testOutgoingFailureDoesNotPreventIncomingRefresh() async {
        var reads: [String] = [], errors: [String] = []
        let queue = QuotaRefreshQueue(minimumSpacing: 0) { request in
            reads.append(request.accountID)
            if request.accountID == self.accountA { errors.append(request.accountID) }
            return nil // A terminal error is reported on that account, then the queue continues.
        }
        queue.switched(from: accountA, to: accountB)
        await drainTasks()
        XCTAssertEqual(errors, [accountA])
        XCTAssertEqual(reads, [accountB, accountA])
        queue.isPaused = true
    }

    func testCooldownDefersCurrentWithoutBlockingOthersOrLosingRetry() async {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var reads: [String] = []
        let queue = QuotaRefreshQueue(minimumSpacing: 0, now: { now }) { request in
            reads.append(request.accountID)
            return reads.count == 1 ? now.addingTimeInterval(60) : nil
        }
        queue.switched(from: accountA, to: accountB)
        await drainTasks()
        XCTAssertEqual(reads, [accountB, accountA])
        queue.isPaused = true
        now.addTimeInterval(60)
        queue.isPaused = false
        await drainTasks()
        XCTAssertEqual(reads, [accountB, accountA, accountB])
        queue.isPaused = true
    }

    func testNotReadyAccountDoesNotBlockAnotherSwitch() async {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var reads: [String] = []
        let queue = QuotaRefreshQueue(minimumSpacing: 0, now: { now }) { request in
            reads.append(request.accountID)
            if request.accountID == self.accountB, reads.filter({ $0 == self.accountB }).count == 1 {
                return now.addingTimeInterval(10)
            }
            return nil
        }
        queue.switched(from: accountA, to: accountB)
        await drainTasks()
        queue.switched(from: accountB, to: accountC)
        await drainTasks()
        XCTAssertEqual(reads, [accountB, accountA, accountC, accountB])
        queue.isPaused = true
        now.addTimeInterval(10)
        queue.isPaused = false
        await drainTasks()
        XCTAssertEqual(reads, [accountB, accountA, accountC, accountB])
        queue.isPaused = true
    }

    func testSwitchDuringInflightReadKeepsNewRefreshForThatAccount() async {
        var reads: [String] = []
        var release: CheckedContinuation<Date?, Never>?
        let queue = QuotaRefreshQueue(minimumSpacing: 0) { request in
            reads.append(request.accountID)
            if reads.count == 1 { return await withCheckedContinuation { release = $0 } }
            return nil
        }
        queue.enqueue(accountA)
        await drainTasks()
        XCTAssertEqual(reads, [accountA])
        queue.isPaused = true
        queue.switched(from: accountA, to: accountB)
        queue.enqueue(accountB)
        release?.resume(returning: nil)
        await drainTasks()
        XCTAssertEqual(reads, [accountA])
        queue.isPaused = false
        await drainTasks()
        XCTAssertEqual(reads, [accountA, accountB, accountA])
        queue.isPaused = true
    }

    func testPauseBetweenSchedulingAndExecutionDoesNotLoseOrDuplicateRequest() async {
        var reads: [String] = []
        let queue = QuotaRefreshQueue(minimumSpacing: 0) { reads.append($0.accountID); return nil }
        queue.enqueue(accountA)
        queue.isPaused = true
        queue.switched(from: accountA, to: accountB)
        await drainTasks()
        XCTAssertTrue(reads.isEmpty)
        queue.isPaused = false
        await drainTasks()
        XCTAssertEqual(reads, [accountB, accountA])
        queue.isPaused = true
    }

    func testMissingOrIdenticalSourceRefreshesTargetOnce() async {
        for source in [nil, accountA] {
            var reads: [String] = []
            let queue = QuotaRefreshQueue(minimumSpacing: 0) { reads.append($0.accountID); return nil }
            queue.switched(from: source, to: accountA)
            await drainTasks()
            XCTAssertEqual(reads, [accountA])
            queue.isPaused = true
        }
    }

    func testCredentialPublicationAfterReadinessDeadlineStillSchedulesRecovery() async {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var reasons: [QuotaRefreshQueue.Reason] = []
        let queue = QuotaRefreshQueue(minimumSpacing: 0, now: { now }) { reasons.append($0.reason); return nil }
        queue.observedAccount(accountA)
        queue.observedCredential(accountID: accountA, signature: "first")
        await drainTasks()
        XCTAssertTrue(reasons.isEmpty)
        queue.enqueueCurrent(accountA, reason: .accountChanged)
        await drainTasks()
        now.addTimeInterval(600)
        queue.observedCredential(accountID: accountA, signature: "renewed")
        queue.observedCredential(accountID: accountA, signature: "renewed")
        await drainTasks()
        XCTAssertEqual(reasons, [.accountChanged, .credentialsChanged])
        queue.isPaused = true
    }
}
