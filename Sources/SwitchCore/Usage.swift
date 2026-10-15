import Foundation

public enum UsageOrigin: String, Codable, Sendable {
    case localCache, live, estimate

}
public struct QuotaWindow: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public var resetIsEstimate: Bool
    public var observedAt: Date?
    public var origin: UsageOrigin?
    public var resetObservedAt: Date?
    public var resetOrigin: UsageOrigin?
    public var resetKnownAbsent: Bool?
    public init(id: String, title: String, usedPercent: Double, resetsAt: Date? = nil, resetIsEstimate: Bool = false, resetKnownAbsent: Bool? = nil) {
        self.id = id; self.title = title; self.usedPercent = min(100, max(0, usedPercent))
        self.resetsAt = resetsAt; self.resetIsEstimate = resetIsEstimate
        self.resetKnownAbsent = resetKnownAbsent
    }
    public func attributed(at date: Date, origin: UsageOrigin) -> Self {
        var result = self
        result.observedAt = observedAt ?? date; result.origin = self.origin ?? origin
        if resetsAt != nil {
            result.resetObservedAt = resetObservedAt ?? date
            result.resetOrigin = resetOrigin ?? (resetIsEstimate ? .estimate : origin)
        }
        return result
    }
}
public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var accountID: String
    public var organizationID: String?
    public var observedAt: Date
    public var origin: UsageOrigin
    public var windows: [QuotaWindow]
    public init(accountID: String, organizationID: String? = nil, observedAt: Date, origin: UsageOrigin, windows: [QuotaWindow]) {
        self.accountID = accountID; self.organizationID = organizationID; self.observedAt = observedAt
        self.origin = origin; self.windows = windows.map { $0.attributed(at: observedAt, origin: origin) }
    }
}
public extension UsageSnapshot {
    /// Migration also handles local snapshots that retained individual server windows.
    func onlineOnly() -> UsageSnapshot? {
        var result = self
        result.windows = windows.compactMap { window in
            guard (window.origin ?? origin) == .live else { return nil }
            var kept = window.attributed(at: observedAt, origin: origin)
            if kept.resetIsEstimate || (kept.resetOrigin ?? origin) != .live {
                kept.resetsAt = nil; kept.resetObservedAt = nil; kept.resetOrigin = nil; kept.resetIsEstimate = false
                kept.resetKnownAbsent = nil
            }
            return kept
        }
        guard !result.windows.isEmpty else { return nil }
        result.origin = .live
        result.observedAt = result.windows.compactMap(\.observedAt).min() ?? observedAt
        return result
    }
}
public struct QuotaProjection: Sendable {
    public var remainingPercent: Double?
    public var lowerBound: Double?
    public var upperBound: Double?
    public var caption: String
    public var stale: Bool
    public var resetPending: Bool
}
public enum QuotaEstimator {
    /// Subscription limits are not a fixed token bucket, and transcripts name no account,
    /// so local token counts are never turned into quota.
    public static func project(_ window: QuotaWindow, snapshot: UsageSnapshot, active: Bool,
                               now: Date = Date(), freshFor: TimeInterval = 960) -> QuotaProjection {
        let age = max(0, now.timeIntervalSince(window.observedAt ?? snapshot.observedAt))
        if let reset = window.resetsAt, now >= reset {
            return .init(remainingPercent: nil, lowerBound: nil, upperBound: nil,
                         caption: L10n.tr("Reset expected · Awaiting confirmation from the current account"), stale: true, resetPending: true)
        }
        return .init(remainingPercent: max(0, 100 - window.usedPercent), lowerBound: nil, upperBound: nil,
                     caption: L10n.tr("Remaining quota"),
                     stale: age > freshFor, resetPending: false)
    }
}

public struct TokenCounts: Codable, Equatable, Sendable {
    public var input: Int = 0
    public var output: Int = 0
    public var cacheRead: Int = 0
    public var cacheWrite: Int = 0
    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
    }
    public var total: Int { input + output + cacheRead + cacheWrite }
    public static func + (lhs: Self, rhs: Self) -> Self {
        .init(input: lhs.input + rhs.input, output: lhs.output + rhs.output,
              cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite)
    }
}
public struct TokenEvent: Codable, Sendable {
    public var requestID: String
    public var messageID: String
    public var sessionID: String
    public var accountID: String?
    public var timestamp: Date
    public var model: String
    public var counts: TokenCounts
    public var incomplete: Bool
    public var deduplicationKey: String { requestID + ":" + messageID }
    public init(requestID: String, messageID: String, sessionID: String, accountID: String?, timestamp: Date,
                model: String, counts: TokenCounts, incomplete: Bool) {
        self.requestID = requestID; self.messageID = messageID; self.sessionID = sessionID; self.accountID = accountID
        self.timestamp = timestamp; self.model = model; self.counts = counts; self.incomplete = incomplete
    }
}
public struct ModelTotal: Identifiable, Sendable {
    public var id: String { model }
    public var model: String
    public var counts: TokenCounts
    public var requests: Int
}
public struct TokenReport: Sendable {
    public var totals = TokenCounts()
    public var models: [ModelTotal] = []
    public var events: [TokenEvent] = []
    public var incompleteRequests = 0
    public var unattributedRequests = 0
    public var scannedFiles = 0
    public var skippedFiles = 0
    public var partial = false
    public init() {}
    public static func aggregate(_ events: [TokenEvent], since: Date = .distantPast) -> TokenReport {
        var unique: [String: TokenEvent] = [:]
        for event in events {
            if let old = unique[event.deduplicationKey] {
                if old.incomplete && !event.incomplete { unique[event.deduplicationKey] = event }
                else if old.incomplete == event.incomplete && event.counts.total >= old.counts.total {
                    unique[event.deduplicationKey] = event
                }
            } else { unique[event.deduplicationKey] = event }
        }
        var report = TokenReport()
        report.events = unique.values.filter { $0.timestamp >= since }.sorted { $0.timestamp < $1.timestamp }
        var models: [String: ModelTotal] = [:]
        for event in report.events {
            if event.incomplete { report.incompleteRequests += 1; continue }
            report.totals = report.totals + event.counts
            if event.accountID == nil { report.unattributedRequests += 1 }
            var total = models[event.model] ?? ModelTotal(model: event.model, counts: .init(), requests: 0)
            total.counts = total.counts + event.counts; total.requests += 1; models[event.model] = total
        }
        report.models = models.values.sorted { $0.counts.total > $1.counts.total }
        return report
    }
}
