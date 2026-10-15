import Foundation

/// Shares one authorized Keychain read across accounts. Nothing is persisted.
final class QuotaKeyAccess: @unchecked Sendable {
    private let lock = NSCondition()
    private var cached: Data?
    private var loading = false
    private var generation = 0
    var available: Bool {
        lock.lock(); defer { lock.unlock() }
        return cached != nil
    }
    func read(allowPrompt: Bool, load: (Bool) throws -> Data) throws -> Data {
        lock.lock()
        while loading { lock.wait() }
        if let cached { lock.unlock(); return cached }
        loading = true
        let started = generation
        lock.unlock()
        let result = Result { try load(allowPrompt) }
        lock.lock()
        if generation == started, case .success(let value) = result { cached = value }
        loading = false; lock.broadcast(); lock.unlock()
        return try result.get()
    }
    func clear() {
        lock.lock(); defer { lock.unlock() }
        if let count = cached?.count { cached?.resetBytes(in: 0..<count) }
        cached = nil
        generation += 1
    }
    deinit { clear() }
}
