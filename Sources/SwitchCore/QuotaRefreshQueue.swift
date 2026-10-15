import Foundation

/// Serializes automatic quota reads without dropping the other half of an account switch.
@MainActor
public final class QuotaRefreshQueue {
    public enum Reason: Equatable { case accountChanged, savedLogin, credentialsChanged, recovery, lifecycle, reset, periodic }
    public struct Request {
        public let accountID: String
        public let readinessDeadline: Date
        public let reason: Reason
        var notBefore: Date
    }
    public var isPaused = false { didSet { startNext() } }
    private var lastAccountID: String?
    private var credentialSignatures: [String: String] = [:]
    private var pending: [Request] = []
    private var running: Request?
    private var wake: Task<Void, Never>?
    private let now: () -> Date
    private let minimumSpacing: TimeInterval
    private var nextSlot = Date.distantPast
    private var lastServedAccountID: String?
    private let refresh: (Request) async -> Date?

    /// A returned date defers this account without blocking other accounts that are ready.
    public init(minimumSpacing: TimeInterval = 15, now: @escaping () -> Date = Date.init, refresh: @escaping (Request) async -> Date?) {
        self.minimumSpacing = minimumSpacing; self.now = now; self.refresh = refresh
    }

    public func enqueuePeriodic(_ accountID: String) { enqueue(accountID, afterSwitch: false, reason: .periodic) }
    public func discard(_ accountID: String) { pending.removeAll { $0.accountID == accountID }; startNext() }
    public func discardPeriodic() { pending.removeAll { $0.reason == .periodic }; startNext() }
    /// Manual work shares the automatic queue's spacing and satisfies pending reads on success.
    public func completedManualRead(accountID: String, succeeded: Bool) {
        nextSlot = now().addingTimeInterval(minimumSpacing)
        if succeeded { pending.removeAll { $0.accountID == accountID } }
        startNext()
    }

    public func observedAccount(_ accountID: String) {
        let previous = lastAccountID
        lastAccountID = accountID
        if let previous, previous != accountID { switched(from: previous, to: accountID) }
    }

    /// Called only after a successful switch. The subsequent local scan must not enqueue it again.
    public func switched(from source: String?, to target: String) {
        lastAccountID = target
        enqueue(target, afterSwitch: true, reason: .accountChanged)
        if let source, source != target { enqueue(source, afterSwitch: true, reason: .accountChanged) }
    }

    /// Saving a newly discovered login coalesces with its pending or in-flight switch refresh.
    public func enqueue(_ accountID: String) { enqueue(accountID, afterSwitch: false, reason: .savedLogin) }
    public func enqueueRecovery(_ accountID: String) { enqueue(accountID, afterSwitch: false, reason: .recovery) }
    public func enqueueCurrent(_ accountID: String, reason: Reason) {
        lastAccountID = accountID
        enqueue(accountID, afterSwitch: false, reason: reason)
    }
    /// Encrypted-cache changes are cheap to observe; the reader still verifies that the selected token changed.
    public func observedCredential(accountID: String, signature: String) {
        let previous = credentialSignatures.updateValue(signature, forKey: accountID)
        if let previous, previous != signature {
            enqueue(accountID, afterSwitch: true, reason: .credentialsChanged)
        }
    }

    private func enqueue(_ accountID: String, afterSwitch: Bool, reason: Reason) {
        if let index = pending.firstIndex(where: { $0.accountID == accountID }) {
            if afterSwitch {
                let date = now()
                pending[index] = Request(accountID: accountID, readinessDeadline: date.addingTimeInterval(120), reason: reason, notBefore: date)
            }
            startNext(); return
        }
        guard afterSwitch || running?.accountID != accountID else { return }
        let date = now()
        pending.append(Request(accountID: accountID, readinessDeadline: date.addingTimeInterval(120), reason: reason, notBefore: date))
        startNext()
    }

    private func startNext() {
        wake?.cancel(); wake = nil
        guard !isPaused, running == nil else { return }
        let date = now()
        let other = pending.firstIndex { $0.accountID != lastAccountID && max($0.notBefore, nextSlot) <= date }
        let current = pending.firstIndex { $0.accountID == lastAccountID && max($0.notBefore, nextSlot) <= date }
        let preferred = lastServedAccountID == lastAccountID && other != nil ? other : current
        guard let index = preferred ?? pending.firstIndex(where: { max($0.notBefore, nextSlot) <= date }) else {
            if let next = pending.map({ max($0.notBefore, nextSlot) }).min() {
                // Bound each sleep so changes to the wall clock cannot strand a queued read.
                let delay = min(60, max(0.01, next.timeIntervalSince(date)))
                wake = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
                    self?.startNext()
                }
            }
            return
        }
        let request = pending.remove(at: index)
        running = request
        Task {
            // A switch or local scan can start between scheduling this task and entering it.
            if isPaused {
                if !pending.contains(where: { $0.accountID == request.accountID }) { pending.insert(request, at: 0) }
            } else {
                let retryAt = await refresh(request)
                lastServedAccountID = request.accountID
                nextSlot = now().addingTimeInterval(minimumSpacing)
                if let retryAt, !pending.contains(where: { $0.accountID == request.accountID }) {
                    var retry = request
                    retry.notBefore = max(retryAt, now().addingTimeInterval(0.1))
                    pending.append(retry)
                }
            }
            running = nil
            startNext()
        }
    }
}
