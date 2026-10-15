import Foundation

public enum QuotaReadingState: Equatable, Sendable {
    case unknown, recorded, estimated, stale, resetPending
}

public struct QuotaReadout: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// The last measured value stays visible even while freshness or a reset awaits confirmation.
    public var remainingPercent: Double?
    public var state: QuotaReadingState
    public var resetsAt: Date?
    public var resetIsEstimate: Bool
    public var lowerBound: Double?
    public var upperBound: Double?
    public var observedAt: Date?
    public var origin: UsageOrigin
    public var resetKnownAbsent: Bool

    /// An untouched five-hour window has no reset yet: it opens with the next request.
    public var awaitingFirstUse: Bool {
        id == "five_hour" && [.recorded, .stale].contains(state) && origin == .live &&
            resetsAt == nil && resetKnownAbsent && remainingPercent == 100
    }

    public var shortTitle: String { L10n.quotaShortTitle(id) ?? title }

    /// Freshness gates decisions separately from displaying the last measurement.
    public var currentRemainingPercent: Double? {
        state == .recorded || state == .estimated ? remainingPercent : nil
    }

    public var lastRecordedPercentageText: String? {
        guard state == .stale || state == .resetPending, let remainingPercent else { return nil }
        return (remainingPercent / 100).formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale))
    }

    public var percentageText: String {
        guard let remainingPercent else { return "—" }
        return (state == .estimated ? "≈" : "") + (remainingPercent / 100).formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale))
    }

    public static func make(id: String, title: String, window: QuotaWindow?, snapshot: UsageSnapshot?,
                            active: Bool, projection: QuotaProjection? = nil, now: Date = Date(), freshFor: TimeInterval = 960) -> Self {
        guard let window, let snapshot, (window.observedAt ?? snapshot.observedAt) <= now.addingTimeInterval(60),
              window.usedPercent.isFinite, (0...100).contains(window.usedPercent) else {
            return .init(id: id, title: title, state: .unknown)
        }
        if let reset = window.resetsAt, now >= reset {
            return .init(id: id, title: title, remainingPercent: 100 - window.usedPercent, state: .resetPending, resetsAt: reset,
                         resetIsEstimate: window.resetIsEstimate, observedAt: window.observedAt ?? snapshot.observedAt,
                         origin: window.origin ?? snapshot.origin)
        }
        let value = projection ?? QuotaEstimator.project(window, snapshot: snapshot, active: active, now: now, freshFor: freshFor)
        guard let percent = value.remainingPercent, percent.isFinite else {
            return .init(id: id, title: title, state: .unknown)
        }
        return .init(id: id, title: title, remainingPercent: min(100, max(0, percent)),
                     state: value.stale ? .stale : value.lowerBound == nil && (window.origin ?? snapshot.origin) != .estimate ? .recorded : .estimated,
                     resetsAt: window.resetsAt, resetIsEstimate: window.resetIsEstimate,
                     lowerBound: value.lowerBound, upperBound: value.upperBound, observedAt: window.observedAt ?? snapshot.observedAt,
                     origin: window.origin ?? snapshot.origin, resetKnownAbsent: window.resetKnownAbsent == true)
    }

    private init(id: String, title: String, remainingPercent: Double? = nil, state: QuotaReadingState,
                 resetsAt: Date? = nil, resetIsEstimate: Bool = false, lowerBound: Double? = nil, upperBound: Double? = nil,
                 observedAt: Date? = nil, origin: UsageOrigin = .localCache, resetKnownAbsent: Bool = false) {
        self.id = id; self.title = title; self.remainingPercent = remainingPercent; self.state = state
        self.resetsAt = resetsAt; self.resetIsEstimate = resetIsEstimate
        self.lowerBound = lowerBound; self.upperBound = upperBound
        self.observedAt = observedAt; self.origin = origin
        self.resetKnownAbsent = resetKnownAbsent
    }
}

public enum AccountQuotaPresentation {
    /// Keep both slots even when a fetch is missing. Unknown is never rendered as zero.
    public static func rows(accountID: String, snapshot: UsageSnapshot?, active: Bool,
                            projections: [String: QuotaProjection] = [:], now: Date = Date(), freshFor: TimeInterval = 960) -> [QuotaReadout] {
        let owned = snapshot?.accountID == accountID ? snapshot : nil
        return ["five_hour", "seven_day"].map { id in
            QuotaReadout.make(id: id, title: L10n.quotaTitle(id, fallback: id), window: owned?.windows.first { $0.id == id }, snapshot: owned,
                             active: active, projection: projections[id], now: now, freshFor: freshFor)
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
        guard currentRemainingPercent != nil, let reset = resetsAt, !resetIsEstimate,
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

public extension QuotaWindow {
    /// Elapsed resets are presentation state, never a new measurement.
    func rolledOver(now: Date) -> QuotaWindow {
        self
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
        result.windows = windows.map { original in
            let window = original.attributed(at: observedAt, origin: origin)
            // A stated reset from earlier in the same window beats an inferred bound.
            guard window.resetsAt == nil || window.resetIsEstimate,
                  let old = previous.windows.first(where: { $0.id == window.id }),
                  let reset = old.resetsAt, !old.resetIsEstimate, reset > observedAt,
                  ResetInference.lengths[window.id].map({ reset.addingTimeInterval(-$0) <= observedAt }) ?? true,
                  window.usedPercent >= old.usedPercent else { return window }
            var updated = window; updated.resetsAt = reset; updated.resetIsEstimate = false
            updated.resetObservedAt = old.resetObservedAt ?? previous.observedAt
            updated.resetOrigin = old.resetOrigin ?? previous.origin
            return updated
        }
        // Claude's local samples only carry the 5-hour and 7-day windows; the others keep the server's last reading.
        result.windows += previous.windows.filter { old in !windows.contains { $0.id == old.id } }
            .map { $0.attributed(at: previous.observedAt, origin: previous.origin) }
        return result
    }
}
