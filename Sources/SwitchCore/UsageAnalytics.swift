import Foundation

/// Claude Desktop activity semantics: count main-file user/assistant rows;
/// sum every assistant usage row, including subagents, without request deduplication.
public struct ActivityModel: Codable, Sendable, Identifiable {
    public var id: String { model }
    public var model: String
    public var counts = TokenCounts()
    public var messages = 0
    public init(model: String) { self.model = model }
}

public struct ActivityDay: Codable, Sendable {
    public var date: Date
    public var messages = 0
    public var sessions = 0
    public var hours: [Int: Int] = [:]
    public var models: [String: ActivityModel] = [:]
    public init(date: Date) { self.date = date }
    public var totals: TokenCounts { models.values.reduce(TokenCounts()) { $0 + $1.counts } }
    public mutating func merge(_ other: ActivityDay) {
        messages += other.messages; sessions += other.sessions
        for (hour, count) in other.hours { hours[hour, default: 0] += count }
        for (name, value) in other.models {
            var model = models[name] ?? ActivityModel(model: name)
            model.counts = model.counts + value.counts; model.messages += value.messages
            models[name] = model
        }
    }
}

public struct UsageAnalytics: Sendable {
    public var days: [ActivityDay] = []
    public var scannedFiles = 0
    public var totalFiles = 0
    public var processedBytes: Int64 = 0
    public var totalBytes: Int64 = 0
    public var skippedFiles = 0
    public var skippedLines = 0
    public var partial = false
    public var cacheWriteFailed = false
    public init() {}
    public var messages: Int { days.reduce(0) { $0 + $1.messages } }
    public var sessions: Int { days.reduce(0) { $0 + $1.sessions } }
    public var activeDays: Int { days.filter { $0.messages > 0 }.count }
    public var totals: TokenCounts { days.reduce(TokenCounts()) { $0 + $1.totals } }
    public var peakHour: Int? {
        var hours: [Int: Int] = [:]
        for day in days { for (hour, count) in day.hours { hours[hour, default: 0] += count } }
        return hours.keys.sorted().max { hours[$0, default: 0] < hours[$1, default: 0] }
    }
    public var models: [ActivityModel] {
        var combined = ActivityDay(date: .distantPast)
        for day in days { combined.merge(day) }
        return combined.models.values.sorted { $0.counts.total > $1.counts.total }
    }
    public func filtered(days count: Int, now: Date = Date(), calendar: Calendar = .current) -> Self {
        guard count > 0 else { return self }
        let start = calendar.date(byAdding: .day, value: -(count - 1), to: calendar.startOfDay(for: now))!
        var copy = self; copy.days = days.filter { $0.date >= start }; return copy
    }
}
