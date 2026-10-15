import Foundation

/// Only documented window shapes are accepted. Missing data never becomes zero usage.
public enum UsageResponseParser {
    public static let windowIDs = ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus", "seven_day_oauth_apps", "seven_day_cowork"]
    public static func windows(_ root: JSONValue, at date: Date) -> [QuotaWindow] {
        var result: [QuotaWindow] = []
        for id in windowIDs {
            guard let used = percent(root[id]["utilization"]) else { continue }
            result.append(QuotaWindow(id: id, title: title(id), usedPercent: used,
                                      resetsAt: Dates.parse(root[id]["resets_at"]),
                                      resetKnownAbsent: root[id].object?["resets_at"] == .null).attributed(at: date, origin: .live))
        }
        for item in (root["limits"].array ?? []).prefix(64) {
            guard item["kind"].string == "weekly_scoped", let used = percent(item["percent"]) ?? percent(item["utilization"]) else { continue }
            let scope = item["scope"]["model"]
            guard let name = scope["display_name"].string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, name.count <= 80, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { continue }
            let stable = scope["id"].string ?? name.lowercased(with: Locale(identifier: "en_US_POSIX"))
            guard !stable.isEmpty, stable.count <= 128 else { continue }
            let id = "weekly-model:" + stable
            guard !result.contains(where: { $0.id == id }) else { continue }
            result.append(QuotaWindow(id: id, title: L10n.tr("Weekly · {0}", L10n.argument(name)), usedPercent: used,
                                      resetsAt: Dates.parse(item["resets_at"])).attributed(at: date, origin: .live))
        }
        return result
    }
    private static func percent(_ value: JSONValue) -> Double? {
        guard let number = value.number, number.isFinite, (0...100).contains(number) else { return nil }
        return number
    }
    private static func title(_ id: String) -> String {
        switch id {
        case "seven_day_oauth_apps": return L10n.tr("Weekly · OAuth apps")
        case "seven_day_cowork": return L10n.tr("Weekly · Cowork")
        default: return L10n.quotaTitle(id, fallback: id)
        }
    }
}
