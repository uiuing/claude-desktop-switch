import Foundation

public enum QuotaReadingState: Equatable, Sendable {
    case unknown, recorded, estimated
}

public struct QuotaReadout: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var remainingPercent: Double?
    public var state: QuotaReadingState
    public var resetsAt: Date?
    public var resetIsEstimate: Bool
    public var lowerBound: Double?
    public var upperBound: Double?

    /// An untouched five-hour window has no reset yet: it opens with the next request.
    public var awaitingFirstUse: Bool {
        id == "five_hour" && state == .recorded && resetsAt == nil && remainingPercent == 100
    }

    public var shortTitle: String { L10n.quotaShortTitle(id) ?? title }

    public var percentageText: String {
        guard let remainingPercent else { return "—" }
        return (state == .estimated ? "≈" : "") + (remainingPercent / 100).formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale))
    }

    public static func make(id: String, title: String, window: QuotaWindow?, snapshot: UsageSnapshot?,
                            active: Bool, projection: QuotaProjection? = nil, now: Date = Date()) -> Self {
        guard let window, let snapshot, snapshot.observedAt <= now.addingTimeInterval(60),
              window.usedPercent.isFinite, (0...100).contains(window.usedPercent) else {
            return .init(id: id, title: title, state: .unknown)
        }
        if let reset = window.resetsAt, now >= reset {
            let fresh = window.rolledOver(now: now)
            return .init(id: id, title: title, remainingPercent: 100 - fresh.usedPercent, state: .recorded,
                         resetsAt: fresh.resetsAt, resetIsEstimate: fresh.resetIsEstimate)
        }
        let value = projection ?? QuotaEstimator.project(window, snapshot: snapshot, active: active, now: now)
        guard let percent = value.remainingPercent, percent.isFinite else {
            return .init(id: id, title: title, state: .unknown)
        }
        return .init(id: id, title: title, remainingPercent: min(100, max(0, percent)),
                     state: value.lowerBound == nil && snapshot.origin != .estimate ? .recorded : .estimated,
                     resetsAt: window.resetsAt, resetIsEstimate: window.resetIsEstimate,
                     lowerBound: value.lowerBound, upperBound: value.upperBound)
    }

    private init(id: String, title: String, remainingPercent: Double? = nil, state: QuotaReadingState,
                 resetsAt: Date? = nil, resetIsEstimate: Bool = false, lowerBound: Double? = nil, upperBound: Double? = nil) {
        self.id = id; self.title = title; self.remainingPercent = remainingPercent; self.state = state
        self.resetsAt = resetsAt; self.resetIsEstimate = resetIsEstimate
        self.lowerBound = lowerBound; self.upperBound = upperBound
    }
}

public enum AccountQuotaPresentation {
    /// Keep both slots even when a fetch is missing. Unknown is never rendered as zero.
    public static func rows(accountID: String, snapshot: UsageSnapshot?, active: Bool,
                            projections: [String: QuotaProjection] = [:], now: Date = Date()) -> [QuotaReadout] {
        let owned = snapshot?.accountID == accountID ? snapshot : nil
        return ["five_hour", "seven_day"].map { id in
            QuotaReadout.make(id: id, title: L10n.quotaTitle(id, fallback: id), window: owned?.windows.first { $0.id == id }, snapshot: owned,
                             active: active, projection: projections[id], now: now)
        }
    }

    public static func limitingWindow(_ rows: [QuotaReadout]) -> QuotaReadout? {
        guard rows.count == 2, rows.allSatisfy({ $0.remainingPercent != nil }) else { return nil }
        return rows.min { ($0.remainingPercent ?? 100) < ($1.remainingPercent ?? 100) }
    }
}

public extension QuotaReadout {
    /// What would remain now had the window been used evenly since it opened.
    func evenRemaining(now: Date) -> Double? {
        guard remainingPercent != nil, let reset = resetsAt, !resetIsEstimate,
              let length = ResetInference.lengths[id], reset > now else { return nil }
        let left = reset.timeIntervalSince(now)
        guard left < length else { return nil }
        return 100 * left / length
    }
}

/// A saved account worth switching to: the signed-in one is nearly spent, or this one has quota about to go unused.
public struct SwitchAdvice: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case fiveHourLow(String), sevenDayLow(String)
        /// The target's window resets soon with much of it unspent.
        case expiring(QuotaReadout)
    }
    public var accountID: String
    public var reason: Reason
    public var fiveHour: QuotaReadout
}

public enum SwitchAdvisor {
    private static let hour: TimeInterval = 3600

    /// A shortage on the signed-in account comes first; otherwise quota another account is about to lose.
    /// With neither, staying put is better than a switch.
    public static func advice(active: [QuotaReadout], candidates: [(id: String, rows: [QuotaReadout])],
                              now: Date = Date()) -> SwitchAdvice? {
        shortage(active: active, candidates: candidates, now: now) ?? expiring(active: active, candidates: candidates, now: now)
    }

    /// The five-hour window decides first; the weekly window only when it is nearly spent. A window that resets
    /// shortly is waited out. A target must leave clearly more five-hour quota and enough weekly quota.
    private static func shortage(active: [QuotaReadout], candidates: [(id: String, rows: [QuotaReadout])],
                                 now: Date) -> SwitchAdvice? {
        let five = window("five_hour", active), seven = window("seven_day", active)
        let reason: SwitchAdvice.Reason
        let floor: Double
        if let five, let left = five.remainingPercent, left <= 20, !resets(five, within: 0.5 * hour, now: now) {
            reason = .fiveHourLow(five.percentageText); floor = left + 20
        } else if let seven, let left = seven.remainingPercent, left <= 10, !resets(seven, within: hour, now: now) {
            reason = .sevenDayLow(seven.percentageText); floor = 30
        } else { return nil }
        let best = candidates.compactMap { candidate -> (String, QuotaReadout, Double)? in
            guard let target = window("five_hour", candidate.rows), let left = target.remainingPercent,
                  let weekly = window("seven_day", candidate.rows)?.remainingPercent,
                  left >= max(30, floor), weekly >= 20 else { return nil }
            return (candidate.id, target, weekly)
        }.max { ($0.1.remainingPercent ?? 0, $0.2) < ($1.1.remainingPercent ?? 0, $1.2) }
        return best.map { SwitchAdvice(accountID: $0.0, reason: reason, fiveHour: $0.1) }
    }

    /// Weekly quota resetting within a day, or a five-hour window within the hour, is lost unless spent now.
    /// Not worth it when the signed-in account has as much of the same window lapsing by then.
    private static func expiring(active: [QuotaReadout], candidates: [(id: String, rows: [QuotaReadout])],
                                 now: Date) -> SwitchAdvice? {
        let picks = candidates.compactMap { candidate -> (advice: SwitchAdvice, rank: Double)? in
            guard let five = window("five_hour", candidate.rows), let fiveLeft = five.remainingPercent,
                  let seven = window("seven_day", candidate.rows), let sevenLeft = seven.remainingPercent else { return nil }
            if sevenLeft >= 20, fiveLeft >= 30, resets(seven, within: 24 * hour, now: now),
               !lapses(window("seven_day", active), by: seven.resetsAt, floor: 20) {
                return (SwitchAdvice(accountID: candidate.id, reason: .expiring(seven), fiveHour: five), 100 + sevenLeft)
            }
            if fiveLeft >= 50, sevenLeft >= 30, resets(five, within: hour, now: now),
               !lapses(window("five_hour", active), by: five.resetsAt, floor: 50) {
                return (SwitchAdvice(accountID: candidate.id, reason: .expiring(five), fiveHour: five), fiveLeft)
            }
            return nil
        }
        return picks.max { $0.rank < $1.rank }?.advice
    }

    private static func window(_ id: String, _ rows: [QuotaReadout]) -> QuotaReadout? { rows.first { $0.id == id } }
    private static func resets(_ row: QuotaReadout, within interval: TimeInterval, now: Date) -> Bool {
        guard let reset = row.resetsAt else { return false }
        return reset > now && reset.timeIntervalSince(now) <= interval
    }
    private static func lapses(_ row: QuotaReadout?, by date: Date?, floor: Double) -> Bool {
        guard let row, let left = row.remainingPercent, let reset = row.resetsAt, let date else { return false }
        return reset <= date && left >= floor
    }
}

public extension QuotaWindow {
    /// Usage starts again from zero once the reset passes. Weekly windows keep their schedule; a five-hour
    /// window only opens with the next request, so its next reset stays unknown until it is read again.
    func rolledOver(now: Date) -> QuotaWindow {
        guard let reset = resetsAt, now >= reset else { return self }
        var next: Date?
        if id != "five_hour", let length = ResetInference.lengths[id] {
            next = reset.addingTimeInterval(length * (floor(now.timeIntervalSince(reset) / length) + 1))
        }
        return QuotaWindow(id: id, title: title, usedPercent: 0, resetsAt: next, resetIsEstimate: resetIsEstimate)
    }
}

public extension UsageSnapshot {
    func rollingOverElapsedResets(now: Date) -> UsageSnapshot {
        var result = self
        result.windows = windows.map { $0.rolledOver(now: now) }
        return result
    }

    func retainingKnownResets(from previous: UsageSnapshot?) -> UsageSnapshot {
        guard origin == .localCache, let previous, previous.accountID == accountID,
              let organizationID, previous.organizationID == organizationID,
              previous.observedAt <= observedAt else { return self }
        var result = self
        result.windows = windows.map { window in
            // A stated reset from earlier in the same window beats an inferred bound.
            guard window.resetsAt == nil || window.resetIsEstimate,
                  let old = previous.windows.first(where: { $0.id == window.id }),
                  let reset = old.resetsAt, !old.resetIsEstimate, reset > observedAt,
                  ResetInference.lengths[window.id].map({ reset.addingTimeInterval(-$0) <= observedAt }) ?? true,
                  window.usedPercent >= old.usedPercent else { return window }
            var updated = window; updated.resetsAt = reset; updated.resetIsEstimate = false
            return updated
        }
        // Claude's local samples only carry the 5-hour and 7-day windows; the others keep the server's last reading.
        result.windows += previous.windows.filter { old in !windows.contains { $0.id == old.id } }
        return result
    }
}
