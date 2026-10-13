import Foundation

public enum UsageOrigin: String, Codable, Sendable {
    case localCache, live, estimate
    public var title: String {
        switch self { case .localCache: return L10n.tr("Local record"); case .live: return L10n.tr("Live reading"); case .estimate: return L10n.tr("Local estimate") }
    }
}
public struct QuotaWindow: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public var resetIsEstimate: Bool
    public init(id: String, title: String, usedPercent: Double, resetsAt: Date? = nil, resetIsEstimate: Bool = false) {
        self.id = id; self.title = title; self.usedPercent = min(100, max(0, usedPercent))
        self.resetsAt = resetsAt; self.resetIsEstimate = resetIsEstimate
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
        self.origin = origin; self.windows = windows
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
public struct Calibration: Sendable {
    public let tokensPerPercent: Double
    public let sampleCount: Int
    public init?(samples: [(tokens: Int, percentage: Double)]) {
        let ratios = samples.filter { $0.tokens > 0 && $0.percentage > 0 && $0.percentage <= 20 }
            .map { Double($0.tokens) / $0.percentage }.sorted()
        guard ratios.count >= 3 else { return nil }
        tokensPerPercent = ratios[ratios.count / 2]; sampleCount = ratios.count
    }
}
public enum QuotaEstimator {
    /// Subscription limits are not a fixed token bucket. No calibration means no fabricated conversion.
    public static func project(_ window: QuotaWindow, snapshot: UsageSnapshot, active: Bool,
                               tokensSinceObservation: Int = 0, calibration: Calibration? = nil,
                               now: Date = Date()) -> QuotaProjection {
        let age = max(0, now.timeIntervalSince(snapshot.observedAt))
        if let reset = window.resetsAt, now >= reset {
            return .init(remainingPercent: nil, lowerBound: nil, upperBound: nil,
                         caption: L10n.tr("Reset expected · Awaiting confirmation from the current account"), stale: true, resetPending: true)
        }
        let remaining = max(0, 100 - window.usedPercent)
        guard tokensSinceObservation > 0, let calibration else {
            return .init(remainingPercent: remaining, lowerBound: nil, upperBound: nil,
                         caption: active ? snapshot.origin.title : L10n.tr("Last reading · Other devices not checked"),
                         stale: !active || age > 600, resetPending: false)
        }
        let delta = Double(tokensSinceObservation) / calibration.tokensPerPercent
        return .init(remainingPercent: max(0, remaining - delta),
                     lowerBound: max(0, remaining - delta * 1.5), upperBound: max(0, remaining - delta * 0.5),
                     caption: L10n.tr("Estimated from local changes · Excludes other devices"), stale: !active || age > 600, resetPending: false)
    }
}

public enum QuotaCalibrator {
    public static func projection(window: QuotaWindow, snapshot: UsageSnapshot, history: [UsageSnapshot],
                                  report: TokenReport, active: Bool, now: Date = Date()) -> QuotaProjection {
        let fallback = QuotaEstimator.project(window, snapshot: snapshot, active: active, now: now)
        guard ["five_hour", "seven_day"].contains(window.id),
              !report.partial, let reset = window.resetsAt, reset > now, !window.resetIsEstimate else { return fallback }
        let points = Array(history.filter { point in
            point.accountID == snapshot.accountID && point.origin == .live &&
            point.windows.contains { $0.id == window.id && $0.resetsAt == reset && !$0.resetIsEstimate }
        }.sorted { $0.observedAt < $1.observedAt }.suffix(8))
        guard points.count >= 4 else { return fallback }
        var samples: [(tokens: Int, percentage: Double)] = [], models = Set<String>()
        for (before, after) in zip(points, points.dropFirst()) {
            guard after.observedAt.timeIntervalSince(before.observedAt) >= 60,
                  let a = before.windows.first(where: { $0.id == window.id }),
                  let b = after.windows.first(where: { $0.id == window.id }), b.usedPercent > a.usedPercent else { continue }
            let period = report.events.filter { $0.timestamp > before.observedAt && $0.timestamp <= after.observedAt }
            guard !period.isEmpty, !period.contains(where: { $0.accountID == nil || $0.incomplete }) else { continue }
            let owned = period.filter { $0.accountID == snapshot.accountID }
            models.formUnion(owned.map(\.model))
            samples.append((owned.reduce(0) { $0 + $1.counts.total }, b.usedPercent - a.usedPercent))
        }
        let pending = report.events.filter { $0.timestamp > snapshot.observedAt && $0.timestamp <= now }
        guard !pending.contains(where: { $0.accountID == nil || $0.incomplete }) else { return fallback }
        let owned = pending.filter { $0.accountID == snapshot.accountID }
        models.formUnion(owned.map(\.model))
        guard models.count == 1, let calibration = Calibration(samples: samples) else { return fallback }
        return QuotaEstimator.project(window, snapshot: snapshot, active: active,
            tokensSinceObservation: owned.reduce(0) { $0 + $1.counts.total }, calibration: calibration, now: now)
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
