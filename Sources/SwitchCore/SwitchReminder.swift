import Foundation

public struct SwitchReminder: Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case sessionLow, weeklyLow, expiring }
    public let id: UUID
    public let sourceAccountID: String
    public let targetAccountID: String
    public let kind: Kind
    public let remaining: String
    public let exhausted: Bool
    public let needsReview: Bool
    public let expiresAt: Date
}

/// Receipts survive stale readings and restarts. A different backup does not create another low-quota alert.
public struct SwitchReminderPolicy: Codable, Sendable {
    private struct Scope: Codable, Equatable {
        var source: String
        var organization: String?
        var window: String
        var reset: Date?
        var opportunityTarget: String?
        var exhausted: Bool
    }
    private struct Receipt: Codable {
        var scope: Scope
        var id: UUID
        var issuedAt: Date
        var reviewed: Bool
    }
    private var receipts: [Receipt] = []
    public init() {}
    public struct Decision {
        public let reminder: SwitchReminder
        public let shouldNotify: Bool
    }

    public mutating func evaluate(_ ranking: AccountRankingResult, now: Date = Date()) -> Decision? {
        receipts.removeAll { now.timeIntervalSince($0.issuedAt) > 8 * 86400 }
        guard let active = ranking.ranked.first(where: { $0.account.id == ranking.activeID }) else { return nil }
        // With no reset timestamp, only a fresh recovery above the warning band starts a new episode.
        for row in active.rows where AccountRanking.recent(row, now: now) {
            let recovered = (row.remainingPercent ?? 0) > (row.id == "five_hour" ? 25 : 15)
            if recovered {
                receipts.removeAll { $0.scope.source == active.account.id && $0.scope.window == row.id &&
                    $0.scope.reset == nil && $0.scope.opportunityTarget == nil }
            }
        }
        guard let advice = ranking.advice, let target = ranking.bestBackup, advice.accountID == target.account.id else { return nil }
        let kind: SwitchReminder.Kind, row: QuotaReadout
        switch advice.reason {
        case .fiveHourLow:
            guard let value = active.window("five_hour") else { return nil }
            kind = .sessionLow; row = value
        case .sevenDayLow:
            guard let value = active.window("seven_day") else { return nil }
            kind = .weeklyLow; row = value
        case .expiring(let value): kind = .expiring; row = value
        }
        let exhausted = kind != .expiring && row.remainingPercent == 0
        let scope = Scope(source: active.account.id, organization: active.account.organizationID, window: row.id,
                          reset: row.resetsAt, opportunityTarget: kind == .expiring ? target.account.id : nil,
                          exhausted: exhausted)
        let isNew = !receipts.contains { $0.scope == scope }
        if isNew { receipts.append(Receipt(scope: scope, id: UUID(), issuedAt: now, reviewed: false)) }
        receipts = Array(receipts.suffix(32))
        guard let receipt = receipts.first(where: { $0.scope == scope }) else { return nil }
        let deadlines = (active.rows + target.rows).flatMap { value in
            [value.observedAt?.addingTimeInterval(AccountRanking.freshFor), value.resetsAt].compactMap { $0 }
        }
        let expiry = deadlines.filter { $0 > now }.min() ?? now
        return Decision(reminder: SwitchReminder(id: receipt.id, sourceAccountID: active.account.id,
            targetAccountID: target.account.id, kind: kind, remaining: row.percentageText, exhausted: exhausted,
            needsReview: !receipt.reviewed, expiresAt: expiry), shouldNotify: isNew)
    }

    public mutating func acknowledge(_ id: UUID) {
        guard let index = receipts.firstIndex(where: { $0.id == id }) else { return }
        receipts[index].reviewed = true
    }
}
