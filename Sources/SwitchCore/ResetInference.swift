import Foundation

/// One `plan-usage-history` reading: window id → used percent.
public struct UsageSample: Sendable {
    public var time: Date
    public var used: [String: Double]
    public init(time: Date, used: [String: Double]) { self.time = time; self.used = used }
}

/// A reset time the server stated while a limit was hit, as Claude recorded it locally.
public struct ResetHint: Equatable, Sendable {
    public var windowID: String
    public var resetsAt: Date
    public var seenAt: Date
    public init(windowID: String, resetsAt: Date, seenAt: Date) {
        self.windowID = windowID; self.resetsAt = resetsAt; self.seenAt = seenAt
    }
}

public enum ResetInference {
    public static let lengths: [String: TimeInterval] = ["five_hour": 5 * 3600, "seven_day": 7 * 86400,
                                                         "seven_day_sonnet": 7 * 86400, "seven_day_opus": 7 * 86400]

    /// An exact stated reset when one is still current, otherwise the latest the window can reset.
    public static func reset(windowID: String, samples: [UsageSample], hints: [ResetHint],
                             now: Date = Date()) -> (date: Date, isEstimate: Bool)? {
        let exact = hints.filter { $0.windowID == windowID && valid($0, samples: samples, now: now) }
            .max { $0.seenAt < $1.seenAt }
        if let exact { return (exact.resetsAt, false) }
        return latestReset(windowID: windowID, samples: samples).map { ($0, true) }
    }

    /// Usage only falls when its window resets, so a run of non-decreasing readings belongs to one
    /// window, which had started by the run's earliest non-zero reading. Any fall ends the run. A reset hidden
    /// between sparse readings, where new usage climbs past the old value, makes the bound too early.
    public static func latestReset(windowID: String, samples: [UsageSample]) -> Date? {
        guard let length = lengths[windowID] else { return nil }
        let readings = samples.compactMap { s in s.used[windowID].map { (time: s.time, used: $0) } }
            .sorted { $0.time < $1.time }
        guard let last = readings.last, last.used > 0 else { return nil }
        var since = last.time, later = last.used
        for reading in readings.dropLast().reversed() {
            guard last.time.timeIntervalSince(reading.time) < length, reading.used > 0, reading.used <= later else { break }
            since = reading.time; later = reading.used
        }
        return since.addingTimeInterval(length)
    }

    /// A stated reset stops applying once it has passed, or once usage fell after it was seen,
    /// which means the window already reset (an early or purchased reset, for instance).
    static func valid(_ hint: ResetHint, samples: [UsageSample], now: Date) -> Bool {
        guard hint.resetsAt > now, let length = lengths[hint.windowID],
              hint.resetsAt <= hint.seenAt.addingTimeInterval(length + 60) else { return false }
        let readings = samples.compactMap { s in s.used[hint.windowID].map { (time: s.time, used: $0) } }
            .sorted { $0.time < $1.time }
        guard let before = readings.last(where: { $0.time <= hint.seenAt }) else { return true }
        return !readings.contains { $0.time > hint.seenAt && $0.used < before.used }
    }
}
