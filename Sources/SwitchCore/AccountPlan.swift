import Foundation

public enum AccountPlan {
    /// Free needs positive organization evidence; missing paid flags alone do not establish it.
    public static func resolve(tier: String?, capabilities: [String] = [], ravenType: String? = nil,
                               hasMax: Bool? = nil, hasPro: Bool? = nil) -> String? {
        let capabilities = Set(capabilities)
        if capabilities.contains("api") { return nil }
        let words = (tier ?? "").lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        for (word, label) in [("enterprise", "Enterprise"), ("team", "Team")] where words.contains(word) { return label }
        if capabilities.contains("raven") {
            switch ravenType {
            case "team": return "Team"
            case "enterprise": return "Enterprise"
            default: return nil
            }
        }
        let max = words.contains("max") || capabilities.contains("claude_max")
        let pro = words.contains("pro") || capabilities.contains("claude_pro")
        if hasMax == true || max {
            guard hasMax != false else { return nil }
            if let index = words.firstIndex(of: "max"), words.indices.contains(index + 1),
               ["5x", "20x"].contains(words[index + 1]) { return "Max " + words[index + 1] }
            return "Max"
        }
        if hasPro == true || pro { return hasPro == false ? nil : "Pro" }
        let unknownCapability = capabilities.contains { $0.hasPrefix("claude_") && $0 != "claude_free" }
        guard !unknownCapability else { return nil }
        let freeTiers = ["free", "claude_free", "default_claude_free", "default_claude_ai"]
        if freeTiers.contains((tier ?? "").lowercased()) || capabilities.contains("claude_free") { return "Free" }
        if (tier == nil || tier == ""), capabilities.contains("chat") { return "Free" }
        return nil
    }

    public static func profile(_ profile: JSONValue) -> String? {
        let account = profile["account"], organization = profile["organization"]
        for key in ["has_claude_max", "has_claude_pro"] where account[key] != .null && account[key].bool == nil { return nil }
        let value = organization["capabilities"]
        if value != .null, value.array == nil || value.array?.contains(where: { $0.string == nil }) == true { return nil }
        if organization["rate_limit_tier"] != .null, organization["rate_limit_tier"].string == nil { return nil }
        return resolve(tier: organization["rate_limit_tier"].string,
                       capabilities: value.array?.compactMap(\.string) ?? [], ravenType: organization["raven_type"].string,
                       hasMax: account["has_claude_max"].bool, hasPro: account["has_claude_pro"].bool)
    }
}
