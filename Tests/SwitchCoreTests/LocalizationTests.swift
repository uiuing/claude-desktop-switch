import Foundation
import XCTest
@testable import SwitchCore

final class LocalizationTests: XCTestCase {
    func testSystemLanguageMatching() {
        let cases: [(String, AppLanguage)] = [
            ("en-US", .english), ("en-GB", .english), ("zh-CN", .simplifiedChinese),
            ("zh-SG", .simplifiedChinese), ("zh-TW", .traditionalChinese),
            ("zh-HK", .traditionalChinese), ("zh-MO", .traditionalChinese),
            ("zh-Hans-TW", .simplifiedChinese), ("zh-Hant-CN", .traditionalChinese),
            ("zh_Hant_HK", .traditionalChinese), ("ja-JP", .japanese), ("ko-KR", .korean),
            ("es-MX", .spanish), ("fr-CA", .french), ("de-CH", .german),
            ("pt-PT", .portuguese), ("pt-BR", .portuguese), ("ru-RU", .russian)
        ]
        for (identifier, expected) in cases {
            XCTAssertEqual(AppLanguage.resolve("system", preferredLanguages: [identifier]), expected, identifier)
        }
        XCTAssertEqual(AppLanguage.resolve("system", preferredLanguages: ["it-IT", "ja-JP", "en-US"]), .japanese)
        XCTAssertEqual(AppLanguage.resolve("system", preferredLanguages: ["unsupported"]), .english)
        XCTAssertEqual(AppLanguage.resolve("system", preferredLanguages: []), .english)
        XCTAssertEqual(AppLanguage.resolve("unknown-old-setting", preferredLanguages: ["ko-KR"]), .korean)
    }

    func testExplicitChoiceOverridesSystem() {
        for language in AppLanguage.allCases where language != .system {
            XCTAssertEqual(AppLanguage.resolve(language.rawValue, preferredLanguages: ["zh-CN"]), language)
        }
        XCTAssertEqual(Set(AppLanguage.allCases.map(\.nativeName)).count, AppLanguage.allCases.count)
    }

    func testAllPackagedCatalogsHaveCompleteKeysAndPlaceholders() throws {
        let english = try XCTUnwrap(L10n.catalogs["en"])
        XCTAssertGreaterThan(english.count, 250)
        for language in AppLanguage.allCases where language != .system {
            let catalog = try XCTUnwrap(L10n.catalogs[language.rawValue], language.rawValue)
            XCTAssertEqual(Set(catalog.keys), Set(english.keys), language.rawValue)
            for (key, value) in catalog {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(language): \(key)")
                XCTAssertEqual(placeholders(value), placeholders(english[key]!), "\(language): \(key)")
            }
        }
    }

    func testLanguageNamesComeFromTheirOwnCatalogs() throws {
        for language in AppLanguage.allCases where language != .system {
            let expected = try XCTUnwrap(L10n.catalogs[language.rawValue]?["language.nativeName"])
            XCTAssertEqual(language.nativeName, expected)
            XCTAssertNotEqual(language.nativeName, "language.nativeName")
        }
        XCTAssertEqual(AppLanguage.system.nativeName, L10n.tr("Follow system"))
    }

    func testEnglishKeysPreserveDistinctTranslationContexts() throws {
        let english = try XCTUnwrap(L10n.catalogs["en"])
        for (key, value) in english {
            XCTAssertNil(key.range(of: "[\u{3400}-\u{4DBF}\u{4E00}-\u{9FFF}\u{F900}-\u{FAFF}]", options: .regularExpression), key)
            XCTAssertFalse(value.isEmpty, key)
        }
        XCTAssertEqual(english["Messages"], english["analytics.messageCount"])
        XCTAssertEqual(english["Resets at {0}"], english["quota.resetTooltip {0}"])
    }

    func testArgumentsCanMoveAndNeverBecomeFormatStrings() {
        let input = "\u{540D}{1}%@🦊"
        XCTAssertEqual(L10n.interpolate("{1} → {0} / {1}", arguments: [input, "B"]), "B → \(input) / B")
        XCTAssertEqual(L10n.text("Switch to {0}", arguments: [input], language: .japanese), "\(input) \u{306B}\u{5207}\u{308A}\u{66FF}\u{3048}")
        XCTAssertEqual(L10n.text("{0} remaining", arguments: ["52%"], language: .english), "52% remaining")
        XCTAssertEqual(L10n.text("{0} remaining", arguments: ["52%"], language: .traditionalChinese), "\u{5269}\u{9918} 52%")
        XCTAssertEqual(L10n.text("unregistered key", language: .french), "unregistered key")
    }

    func testLanguagePreferenceIsIndependentOfClaudeAndAppleLanguages() throws {
        let suite = "dev.claudeswitch.localization-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("ja", forKey: L10n.preferenceKey)
        let reloaded = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(AppLanguage.resolve(try XCTUnwrap(reloaded.string(forKey: L10n.preferenceKey))), .japanese)
        XCTAssertNil(defaults.persistentDomain(forName: suite)?["AppleLanguages"])
    }

    private func placeholders(_ string: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"\{\d+\}"#)
        let source = string as NSString
        return expression.matches(in: string, range: NSRange(location: 0, length: source.length))
            .map { source.substring(with: $0.range) }.sorted()
    }
}
