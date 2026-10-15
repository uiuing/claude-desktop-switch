import Foundation

public struct QuotaRefreshPreferences: Codable, Equatable, Sendable {
    public var enabled = true
    public var adaptive = true
    public var baselineMinutes = 15
    public var otherAccountsMinutes = 30
    public var minimumMinutes = 1
    public var quietMinutes = 30
    public init() {}
    public var normalized: Self {
        var result = self
        result.baselineMinutes = min(60, max(5, baselineMinutes))
        result.otherAccountsMinutes = min(120, max(15, otherAccountsMinutes))
        result.minimumMinutes = min(result.baselineMinutes, min(5, max(1, minimumMinutes)))
        result.quietMinutes = min(120, max(result.baselineMinutes, quietMinutes))
        return result
    }
    private enum CodingKeys: String, CodingKey { case enabled, adaptive, baselineMinutes, otherAccountsMinutes, minimumMinutes, quietMinutes }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        adaptive = try c.decodeIfPresent(Bool.self, forKey: .adaptive) ?? true
        baselineMinutes = try c.decodeIfPresent(Int.self, forKey: .baselineMinutes) ?? 15
        otherAccountsMinutes = try c.decodeIfPresent(Int.self, forKey: .otherAccountsMinutes) ?? 30
        minimumMinutes = try c.decodeIfPresent(Int.self, forKey: .minimumMinutes) ?? 1
        quietMinutes = try c.decodeIfPresent(Int.self, forKey: .quietMinutes) ?? 30
        self = normalized
    }
}
