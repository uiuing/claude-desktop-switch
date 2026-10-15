import Foundation

/// Shares one authorized Keychain read across accounts. Nothing is persisted.
final class KeychainKeyCache: @unchecked Sendable {
    struct Key {
        var data: Data
        fileprivate let generation: Int
        fileprivate let revision: Int
        let freshlyRead: Bool
    }
    private final class Read {
        let generation: Int
        let allowPrompt: Bool
        var result: Result<Key, Error>?
        init(generation: Int, allowPrompt: Bool) { self.generation = generation; self.allowPrompt = allowPrompt }
    }
    private let lock = NSCondition()
    private var cached: Key?
    private var loading: Read?
    private var generation = 0
    private var revision = 0
    private var rejectedCredentials = Set<String>()
    var available: Bool {
        lock.lock(); defer { lock.unlock() }
        return cached != nil
    }
    func read(allowPrompt: Bool, load: (Bool) throws -> Data) throws -> Data {
        try key(allowPrompt: allowPrompt, load: load).data
    }
    /// Rechecks a suspect key without discarding access already granted to other logins.
    func key(allowPrompt: Bool, replacing previous: Key? = nil, load: (Bool) throws -> Data) throws -> Key {
        lock.lock()
        if let previous, previous.generation != generation { lock.unlock(); throw CancellationError() }
        if let cached, previous == nil || previous?.revision != cached.revision {
            lock.unlock()
            return Key(data: cached.data, generation: cached.generation, revision: cached.revision, freshlyRead: false)
        }
        while let pending = loading {
            while pending.result == nil { lock.wait() }
            guard pending.generation == generation else { lock.unlock(); throw CancellationError() }
            let result = pending.result!
            // An explicit action may continue a silent denial; it never repeats another prompt's denial.
            if case .failure(let failure as UsageFailure) = result, failure == .keychain,
               allowPrompt, !pending.allowPrompt { continue }
            lock.unlock()
            return try result.get()
        }
        let pending = Read(generation: generation, allowPrompt: allowPrompt)
        loading = pending
        lock.unlock()
        let result = Result { try load(allowPrompt) }
        lock.lock()
        let completed: Result<Key, Error>
        if generation != pending.generation {
            completed = .failure(CancellationError())
        } else {
            completed = result.map { value in
                if cached?.data != value { rejectedCredentials.removeAll() }
                revision += 1
                let key = Key(data: value, generation: generation, revision: revision, freshlyRead: true)
                cached = key
                return key
            }
        }
        pending.result = completed
        loading = nil; lock.broadcast(); lock.unlock()
        return try completed.get()
    }
    func rejects(_ credential: String, using key: Key) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return key.generation == generation && cached?.data == key.data && rejectedCredentials.contains(credential)
    }
    func reject(_ credential: String, using key: Key) {
        lock.lock(); defer { lock.unlock() }
        guard key.generation == generation, cached?.data == key.data else { return }
        if rejectedCredentials.count >= 256 { rejectedCredentials.removeAll() }
        rejectedCredentials.insert(credential)
    }
    func clear() {
        lock.lock(); defer { lock.unlock() }
        if let count = cached?.data.count { cached?.data.resetBytes(in: 0..<count) }
        cached = nil
        rejectedCredentials.removeAll()
        generation += 1
    }
    deinit { clear() }
}
