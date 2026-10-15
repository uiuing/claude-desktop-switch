import Foundation

public struct RankedAccount: Equatable, Sendable {
    public enum Availability: Int, Sendable {
        case available, needsRefresh, exhausted, unavailable
    }
    public var account: Account
    public var rows: [QuotaReadout]
    public var availability: Availability
    /// A policy index, not a measurement of tokens or of weekly capacity.
    public var baseScore: Double?
    public var score: Double?
    public var resetBonus: Double
    public var sessionMultiplier: Double?
    public var relativeScore: Double?

    public func window(_ id: String) -> QuotaReadout? { rows.first { $0.id == id } }
}

public struct AccountRankingResult: Equatable, Sendable {
    /// The active account participates normally in the underlying ranking.
    public var ranked: [RankedAccount]
    public var activeID: String?
    public var advice: SwitchAdvice?
    public var bestBackup: RankedAccount? {
        ranked.first { $0.account.id != activeID && $0.availability == .available }
    }
    public var displayAccounts: [Account] {
        let accounts = ranked.map(\.account)
        return accounts.filter { $0.id == activeID } + accounts.filter { $0.id != activeID }
    }
}

public enum AccountRanking {
    public static let freshFor: TimeInterval = 600
    public static let weeklyReserve: Double = 20
    public static let maximumResetBonus: Double = 0.10
    private static let switchBuffer: TimeInterval = 300
    private static let opportunityRamp: TimeInterval = 900

    /// Only these plan labels identify a documented session multiplier. Team alone does not identify a seat.
    public static func sessionMultiplier(plan: String?) -> Double? {
        switch plan {
        case "Pro": return 1
        case "Max 5x": return 5
        case "Max 20x": return 20
        default: return nil
        }
    }

    public static func evaluate(_ candidates: [(account: Account, rows: [QuotaReadout])], activeID: String?,
                                now: Date = Date()) -> AccountRankingResult {
        let ranked = candidates.map { assess($0.account, rows: $0.rows, now: now) }.sorted(by: precedes)
        var result = AccountRankingResult(ranked: ranked, activeID: activeID)
        result.advice = SwitchAdvisor.advice(active: ranked.first { $0.account.id == activeID },
                                            target: result.bestBackup, now: now)
        return result
    }

    static func recent(_ row: QuotaReadout, now: Date) -> Bool {
        guard row.state == .recorded, row.origin == .live, let observed = row.observedAt,
              (0...freshFor).contains(now.timeIntervalSince(observed)), let left = row.remainingPercent,
              left.isFinite, (0...100).contains(left), row.resetsAt.map({ $0 > now }) ?? true else { return false }
        return true
    }

    private static func assess(_ account: Account, rows: [QuotaReadout], now: Date) -> RankedAccount {
        let required = rows.filter { ["five_hour", "seven_day"].contains($0.id) }
        let complete = required.count == 2 && Set(required.map(\.id)).count == 2
        let fresh = complete && required.allSatisfy { recent($0, now: now) }
        let availability: RankedAccount.Availability
        if !account.hasSnapshot || account.loginInvalidAt != nil { availability = .unavailable }
        else if required.contains(where: { recent($0, now: now) && $0.remainingPercent == 0 }) { availability = .exhausted }
        else { availability = fresh ? .available : .needsRefresh }
        let multiplier = sessionMultiplier(plan: account.plan)
        let baseRelative: Double?
        let recorded = complete && required.allSatisfy { row in
            [.recorded, .stale].contains(row.state) && row.origin == .live &&
            row.observedAt.map({ $0 <= now }) == true && (row.resetsAt.map({ $0 > now }) ?? true) &&
            row.remainingPercent.map({ $0.isFinite && (0...100).contains($0) }) == true
        }
        if recorded, let five = required.first(where: { $0.id == "five_hour" })?.remainingPercent,
           let seven = required.first(where: { $0.id == "seven_day" })?.remainingPercent {
            // Weekly capacity is unknown. Below the reserve, discount the session index rather than inventing a weekly multiplier.
            baseRelative = five / 100 * min(1, seven / weeklyReserve)
        } else { baseRelative = nil }
        let bonus = availability == .available ? resetBonus(rows: required, now: now) : 0
        let relative = baseRelative.map { $0 * (1 + bonus) }
        return RankedAccount(account: account, rows: required, availability: availability,
                             baseScore: multiplier.flatMap { scale in baseRelative.map { scale * $0 } },
                             score: multiplier.flatMap { scale in relative.map { scale * $0 } },
                             resetBonus: bonus, sessionMultiplier: multiplier, relativeScore: relative)
    }

    private static func resetBonus(rows: [QuotaReadout], now: Date) -> Double {
        let priorities = rows.compactMap { row -> Double? in
            guard recent(row, now: now), !row.resetIsEstimate, let reset = row.resetsAt,
                  let remaining = row.remainingPercent, let length = ResetInference.lengths[row.id] else { return nil }
            let left = reset.timeIntervalSince(now)
            guard left.isFinite, left > switchBuffer, left < length else { return nil }
            let urgency = 1 - left / length
            // This is a bounded opportunity heuristic, not a prediction of work completed before reset.
            let opportunity = min(1, (left - switchBuffer) / opportunityRamp)
            return remaining / 100 * urgency * opportunity
        }
        // One request consumes both limits. Do not count the same opportunity twice.
        return maximumResetBonus * (priorities.max() ?? 0)
    }

    private static func precedes(_ a: RankedAccount, _ b: RankedAccount) -> Bool {
        if a.availability != b.availability { return a.availability.rawValue < b.availability.rawValue }
        if a.availability == .available || a.availability == .needsRefresh {
            if (a.relativeScore != nil) != (b.relativeScore != nil) { return a.relativeScore != nil }
            guard a.relativeScore != nil, b.relativeScore != nil else { return a.account.id < b.account.id }
            // Unmapped plans have a relative order, but never masquerade as Pro-equivalent capacity.
            if (a.score != nil) != (b.score != nil) { return a.score != nil }
            let lhs = a.score ?? a.relativeScore ?? 0, rhs = b.score ?? b.relativeScore ?? 0
            if lhs != rhs { return lhs > rhs }
            let weeklyA = a.window("seven_day")?.remainingPercent ?? 0, weeklyB = b.window("seven_day")?.remainingPercent ?? 0
            if weeklyA != weeklyB { return weeklyA > weeklyB }
        }
        // A strict final key keeps ties independent of dictionary iteration, locale and email changes.
        return a.account.id < b.account.id
    }

}

public enum SwitchAdvisor {
    /// Consume the ranked backup; never select a different account with a second scoring rule.
    public static func advice(active: RankedAccount?, target: RankedAccount?, now: Date = Date()) -> SwitchAdvice? {
        guard let active, let target, target.account.id != active.account.id, target.availability == .available,
              target.rows.allSatisfy({ AccountRanking.recent($0, now: now) }),
              let five = target.window("five_hour"), let targetFive = five.remainingPercent,
              let seven = target.window("seven_day"), let targetSeven = seven.remainingPercent else { return nil }
        func result(_ reason: SwitchAdvice.Reason) -> SwitchAdvice {
            SwitchAdvice(accountID: target.account.id, reason: reason, fiveHour: five)
        }
        // An exhausted limit cannot be used while waiting, even when its reset is close.
        if active.availability == .exhausted,
           let blocked = active.rows.first(where: { AccountRanking.recent($0, now: now) && $0.remainingPercent == 0 }) {
            return result(blocked.id == "five_hour" ? .fiveHourLow(blocked.percentageText) : .sevenDayLow(blocked.percentageText))
        }
        guard active.availability == .available, active.rows.allSatisfy({ AccountRanking.recent($0, now: now) }),
              let currentScore = active.score, let targetScore = target.score,
              let currentFive = active.window("five_hour"), let fiveLeft = currentFive.remainingPercent,
              let currentSeven = active.window("seven_day"), let sevenLeft = currentSeven.remainingPercent,
              targetSeven >= AccountRanking.weeklyReserve else { return nil }
        // Different plans have no verified weekly-capacity conversion. Do not trade away weekly headroom for a nominal session gain.
        guard active.sessionMultiplier == target.sessionMultiplier || targetSeven >= sevenLeft else { return nil }
        let gain = targetScore - currentScore
        if gain + 1e-9 >= max(0.2, currentScore * 0.25) {
            if fiveLeft <= 20, !resets(currentFive, within: 1800, now: now) { return result(.fiveHourLow(currentFive.percentageText)) }
            if sevenLeft <= 10, !resets(currentSeven, within: 3600, now: now) { return result(.sevenDayLow(currentSeven.percentageText)) }
        }
        // The reset bonus may reorder close backups; an expiry suggestion still requires at least as much headroom.
        guard active.sessionMultiplier == target.sessionMultiplier, targetScore >= currentScore,
              targetFive >= max(30, fiveLeft), targetSeven >= sevenLeft else { return nil }
        for (row, current, horizon) in [(seven, currentSeven, 86400.0), (five, currentFive, 3600.0)] {
            guard let reset = row.resetsAt, reset.timeIntervalSince(now) >= 300,
                  resets(row, within: horizon, now: now) else { continue }
            if let ownReset = current.resetsAt, !current.resetIsEstimate {
                if ownReset <= reset { continue }
            } else if !current.awaitingFirstUse { continue }
            return result(.expiring(row))
        }
        return nil
    }

    private static func resets(_ row: QuotaReadout, within interval: TimeInterval, now: Date) -> Bool {
        guard let reset = row.resetsAt, !row.resetIsEstimate else { return false }
        return reset > now && reset.timeIntervalSince(now) <= interval
    }
}

/// Positions are fixed for one open menu. New suggestions wait for the next opening; withdrawn ones disappear immediately.
public struct AccountMenuSnapshot: Equatable, Sendable {
    public let accountIDs: [String]
    public let suggestedID: String?
    public init(_ ranking: AccountRankingResult) {
        accountIDs = ranking.displayAccounts.map(\.id)
        suggestedID = ranking.advice?.accountID
    }
    public func accounts(from ranking: AccountRankingResult) -> [Account] {
        let current = Dictionary(uniqueKeysWithValues: ranking.displayAccounts.map { ($0.id, $0) })
        let pinned = accountIDs.compactMap { current[$0] }
        return pinned + ranking.displayAccounts.filter { !accountIDs.contains($0.id) }
    }
    public func advice(from ranking: AccountRankingResult) -> SwitchAdvice? {
        ranking.advice?.accountID == suggestedID ? ranking.advice : nil
    }
}
