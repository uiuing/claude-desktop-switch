import Foundation

/// App-owned preference; never changes AppleLanguages or Claude's preferences.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, english = "en", simplifiedChinese = "zh-Hans", traditionalChinese = "zh-Hant"
    case japanese = "ja", korean = "ko", spanish = "es", french = "fr", german = "de"
    case portuguese = "pt-BR", russian = "ru"

    public var id: String { rawValue }
    public var nativeName: String {
        if self == .system { return L10n.tr("Follow system") }
        return L10n.text("language.nativeName", language: self)
    }

    /// Match BCP-47 scripts before regions, then try each preferred language.
    public static func resolve(_ selection: String, preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        if let explicit = AppLanguage(rawValue: selection), explicit != .system { return explicit }
        for identifier in preferredLanguages {
            let parts = identifier.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").map(String.init)
            guard let base = parts.first else { continue }
            if base == "zh" {
                if parts.contains("hant") { return .traditionalChinese }
                if parts.contains("hans") { return .simplifiedChinese }
                return parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) ? .traditionalChinese : .simplifiedChinese
            }
            if base == "pt" { return .portuguese }
            if let language = AppLanguage(rawValue: base), language != .system { return language }
        }
        return .english
    }
}

public enum L10n {
    public static let preferenceKey = "interfaceLanguage"
    public static var language: AppLanguage {
        AppLanguage.resolve(UserDefaults.standard.string(forKey: preferenceKey) ?? AppLanguage.system.rawValue)
    }
    public static var locale: Locale { Locale(identifier: language.rawValue) }

    // Packaged apps carry resources in Contents/Resources; SwiftPM executables
    // and tests use the generated module accessor in their build directory.
    private static let resourceBundle: Bundle = {
        if let url = Bundle.main.url(forResource: "ClaudeDesktopSwitch_SwitchCore", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()

    // A single resource bundle is shared by the app, command-line product and tests.
    static let catalogs: [String: [String: String]] = {
        var result: [String: [String: String]] = [:]
        for language in AppLanguage.allCases where language != .system {
            guard let url = resourceBundle.url(forResource: language.rawValue, withExtension: "json", subdirectory: "Localizations"),
                  let data = try? Data(contentsOf: url),
                  let entries = try? JSONDecoder().decode([String: String].self, from: data) else { continue }
            result[language.rawValue] = entries
        }
        return result
    }()

    public static func tr(_ key: String, _ arguments: String...) -> String {
        text(key, arguments: arguments, language: language)
    }

    /// Indexed placeholders allow translators to reorder arguments. Substitution is
    /// one pass, so user content containing braces or percent signs remains literal.
    public static func text(_ key: String, arguments: [String] = [], language: AppLanguage) -> String {
        let template = catalogs[language.rawValue]?[key] ?? catalogs["en"]?[key] ?? key
        return interpolate(template, arguments: arguments)
    }

    static func interpolate(_ template: String, arguments: [String]) -> String {
        let expression = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
        let source = template as NSString
        var result = "", cursor = 0
        for match in expression.matches(in: template, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let index = Int(source.substring(with: match.range(at: 1)))!
            result += arguments.indices.contains(index) ? arguments[index] : source.substring(with: match.range)
            cursor = NSMaxRange(match.range)
        }
        return result + source.substring(from: cursor)
    }

    public static func argument<T>(_ value: T) -> String {
        if let number = value as? Int { return self.number(number) }
        return String(describing: value)
    }

    public static func number(_ value: Int) -> String { value.formatted(.number.locale(locale)) }
    /// Window names follow Claude's own usage screen, e.g. "Session limit" and "Weekly · all models".
    public static func quotaTitle(_ id: String, fallback: String) -> String {
        switch id {
        case "five_hour": return tr("quota.session")
        case "seven_day": return tr("quota.weekly")
        case "seven_day_sonnet": return tr("quota.weeklyModel {0}", "Sonnet")
        case "seven_day_opus": return tr("quota.weeklyModel {0}", "Opus")
        default: return fallback
        }
    }
    /// One-word window names for narrow columns and inline summaries.
    public static func quotaShortTitle(_ id: String) -> String? {
        switch id {
        case "five_hour": return tr("quota.sessionShort")
        case "seven_day": return tr("quota.weeklyShort")
        default: return nil
        }
    }
}
