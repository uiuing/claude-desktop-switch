import Foundation

/// Policy only: the queue serializes reads and the client enforces server cooldowns.
public struct QuotaRefreshSchedule {
    public var preferences = QuotaRefreshPreferences()
    public struct Activity {
        public var running: Bool
        public var online: Bool
        public var awake: Bool
        public var permitsAutomaticReads: Bool { running && online && awake }
        public init(running: Bool = false, online: Bool = false, awake: Bool = true) {
            self.running = running; self.online = online; self.awake = awake
        }
    }
    private struct Entry {
        var fingerprint: String?
        var organizationID: String?
        var snapshot: UsageSnapshot?
        var lastAttempt: Date?
        var samples: [Date: Bool] = [:]
        var observationComplete = false
        var sampledAt: Date?
        var quietSince: Date?
        var blocked = false
        var retryAt: Date?
    }
    public var activity = Activity()
    private var entries: [String: Entry] = [:]
    private var currentAccountID: String?
    public init() {}

    public mutating func synchronize(accounts: [Account], snapshots: [String: UsageSnapshot], now: Date) {
        let ids = Set(accounts.map(\.id))
        entries = entries.filter { ids.contains($0.key) }
        for account in accounts {
            if entries[account.id] == nil || entries[account.id]?.organizationID != account.organizationID {
                entries[account.id] = Entry(fingerprint: account.snapshotFingerprint,
                                           organizationID: account.organizationID,
                                           snapshot: snapshots[account.id].flatMap { $0.organizationID == account.organizationID ? $0.onlineOnly() : nil })
            } else if entries[account.id]?.fingerprint != account.snapshotFingerprint {
                entries[account.id]?.fingerprint = account.snapshotFingerprint
                entries[account.id]?.blocked = false
            }
        }
    }
    public mutating func selectCurrent(_ id: String?, now: Date) {
        guard currentAccountID != id else { return }
        currentAccountID = id
        guard let id else { return }
        entries[id]?.samples = [:]
        entries[id]?.sampledAt = nil; entries[id]?.quietSince = nil
    }
    /// One sample per minute, irrespective of how many sessions changed or UI events arrived.
    public mutating func observeTaskChanges(accountID: String, changed: Bool, complete: Bool, at date: Date) {
        guard var entry = entries[accountID] else { return }
        if !complete || changed || entry.sampledAt.map({ date.timeIntervalSince($0) > 90 || date < $0 }) ?? true {
            entry.quietSince = nil
        }
        if complete && !changed && entry.quietSince == nil { entry.quietSince = date }
        let minute = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
        entry.samples = entry.samples.filter { date.timeIntervalSince($0.key) < 300 }
        entry.samples[minute] = (entry.samples[minute] ?? false) || changed
        entry.observationComplete = complete; entry.sampledAt = date
        entries[accountID] = entry
    }
    public func interval(for id: String, current: String?, now: Date) -> TimeInterval {
        let settings = preferences.normalized
        guard id == current else { return TimeInterval(settings.otherAccountsMinutes * 60) }
        let baseline = TimeInterval(settings.baselineMinutes * 60), minimum = TimeInterval(settings.minimumMinutes * 60)
        guard settings.adaptive, let entry = entries[id], entry.observationComplete,
              let sampledAt = entry.sampledAt, (0...90).contains(now.timeIntervalSince(sampledAt)) else { return baseline }
        let changes = entry.samples.filter { now.timeIntervalSince($0.key) < 300 && $0.value }.count
        if changes >= 4 { return minimum }
        if changes >= 2 { return min(baseline, minimum * 2) }
        if changes == 1 { return min(baseline, minimum * 5) }
        if let quietSince = entry.quietSince, now.timeIntervalSince(quietSince) >= 1800 {
            return TimeInterval(settings.quietMinutes * 60)
        }
        return baseline
    }
    public func isBlocked(_ id: String) -> Bool { entries[id]?.blocked == true }
    public mutating func credentialsChanged(_ id: String) { entries[id]?.blocked = false }
    public mutating func began(_ id: String, at date: Date) { entries[id]?.lastAttempt = date }
    public mutating func suspend(_ id: String) { entries[id]?.blocked = true }
    public mutating func deferRead(_ id: String, until: Date) { entries[id]?.retryAt = until }

    public mutating func succeeded(_ snapshot: UsageSnapshot) {
        guard var entry = entries[snapshot.accountID] else { return }
        entry.snapshot = snapshot; entry.blocked = false; entry.retryAt = nil
        entries[snapshot.accountID] = entry
    }

    public func dueAccounts(current: String?, now: Date) -> [String] {
        guard preferences.enabled, activity.permitsAutomaticReads else { return [] }
        return entries.keys.filter { id in
            guard let entry = entries[id], !entry.blocked, (entry.retryAt ?? .distantPast) <= now else { return false }
            let interval = interval(for: id, current: current, now: now)
            let due = max(entry.snapshot?.observedAt.addingTimeInterval(interval) ?? .distantPast,
                          entry.lastAttempt?.addingTimeInterval(interval) ?? .distantPast)
            return due <= now
        }.sorted { a, b in
            if a == current { return true }; if b == current { return false }
            let lhs = entries[a]?.lastAttempt ?? entries[a]?.snapshot?.observedAt ?? .distantPast
            let rhs = entries[b]?.lastAttempt ?? entries[b]?.snapshot?.observedAt ?? .distantPast
            return lhs == rhs ? a < b : lhs < rhs
        }
    }
}
