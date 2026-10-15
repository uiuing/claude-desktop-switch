import Foundation

/// A publication signature is only a wake-up signal; only a successful scan can confirm a saved login.
@MainActor
public final class LoginDiscovery {
    public enum ScanResult { case pending, retry, saved }
    public private(set) var completed = false
    private var startedAt: Date
    private var acceptedSignature: String?
    private var nextScan = Date.distantPast
    private var scanning = false
    private let now: () -> Date
    private let paused: () -> Bool
    private let signature: () async -> String
    private let scan: () async -> ScanResult

    public init(now: @escaping () -> Date = Date.init, paused: @escaping () -> Bool,
                signature: @escaping () async -> String, scan: @escaping () async -> ScanResult) {
        self.now = now; self.paused = paused; self.signature = signature; self.scan = scan
        startedAt = now()
    }
    /// Slow down after fifteen minutes, but keep discovering a login completed later.
    public var pollingInterval: TimeInterval { now().timeIntervalSince(startedAt) < 900 ? 1 : 5 }
    public func resume() { startedAt = now(); nextScan = .distantPast }

    public func poll() async {
        guard !completed, !scanning, !paused(), !Task.isCancelled else { return }
        scanning = true; defer { scanning = false }
        let current = await signature()
        guard !paused(), !Task.isCancelled, current != acceptedSignature || now() >= nextScan else { return }
        let result = await scan()
        guard !paused(), !Task.isCancelled else { return }
        switch result {
        case .saved: completed = true
        case .pending:
            acceptedSignature = current
            nextScan = now().addingTimeInterval(pollingInterval == 1 ? 5 : 15)
        case .retry:
            // Do not acknowledge a publication whose scan failed or could not run.
            break
        }
    }
}

/// Transient snapshot races keep retrying at a bounded rate; unsupported data still needs a manual retry.
public struct LoginSaveRetry {
    public private(set) var showError = false
    private var fingerprint: String?
    private var attempts = 0
    private var retryAt: Date?
    public init() {}
    public mutating func reset() { self = LoginSaveRetry() }
    public mutating func shouldAttempt(_ current: String, manual: Bool = false, now: Date) -> Bool {
        if manual || fingerprint != current {
            reset(); fingerprint = current; return true
        }
        return retryAt.map { $0 <= now } ?? false
    }
    public mutating func failed(transient: Bool, now: Date) -> TimeInterval? {
        attempts = min(attempts + 1, 5)
        showError = !transient || attempts >= 5
        guard transient else { retryAt = nil; return nil }
        let delay: TimeInterval = [1, 2, 5, 15, 30][attempts - 1]
        retryAt = now.addingTimeInterval(delay)
        return delay
    }
}
