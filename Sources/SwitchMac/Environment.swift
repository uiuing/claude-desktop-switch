import Foundation
import SwitchCore
import SwitchStorage
import CryptoKit

public struct MacEnvironment: Sendable {
    public let home: URL
    public var desktop: URL { home.appendingPathComponent("Library/Application Support/Claude") }
    public var root: URL { home.appendingPathComponent("Library/Application Support/Claude Desktop Switch") }
    public var projects: URL { home.appendingPathComponent(".claude/projects") }
    public var codeConfig: URL { home.appendingPathComponent(".claude.json") }
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }
    public var application: URL? {
        [URL(fileURLWithPath: "/Applications/Claude.app"), home.appendingPathComponent("Applications/Claude.app")]
            .first { Bundle(url: $0)?.bundleIdentifier == "com.anthropic.claudefordesktop" }
    }
    public var version: String? { application.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } }
    public func configDigest() throws -> String {
        digest(try SafeFiles.read(desktop.appendingPathComponent("config.json")))
    }
    public var configJournal: URL { desktop.appendingPathComponent("config.json.journal") }
    /// The config Claude will load on its next start. Claude's store writes `config.json.journal`
    /// as "<sha256 of payload> <store digest> <in-flight digest>\n<payload>" and replays it only
    /// when one of the recorded digests matches the current config.json; otherwise it drops it.
    public func effectiveConfig() throws -> JSONValue {
        let stored = try SafeFiles.read(desktop.appendingPathComponent("config.json"))
        let journal = FileManager.default.fileExists(atPath: configJournal.path) ? try? SafeFiles.read(configJournal) : nil
        return try Self.effectiveConfig(stored: stored, journal: journal)
    }
    static func effectiveConfig(stored: Data, journal: Data?) throws -> JSONValue {
        guard let journal, let newline = journal.firstIndex(of: 10) else { return try JSONDecoder().decode(JSONValue.self, from: stored) }
        let header = String(decoding: journal[journal.startIndex..<newline], as: UTF8.self).split(separator: " ").map(String.init)
        let payload = journal[journal.index(after: newline)...]
        guard header.count >= 2, header[0] == digest(Data(payload)), header.dropFirst().contains(digest(stored)),
              let pending = try? JSONDecoder().decode(JSONValue.self, from: Data(payload)) else {
            return try JSONDecoder().decode(JSONValue.self, from: stored)
        }
        return pending
    }
    public func credentialDigest() throws -> String {
        try IdentitySchema.fingerprint(SafeFiles.json(desktop.appendingPathComponent("config.json")))
    }
    /// The account config.json names, or nil after Switch has moved the login out.
    public func lastKnownAccount() throws -> String? {
        guard let value = try SafeFiles.json(desktop.appendingPathComponent("config.json"))["lastKnownAccountUuid"].string else { return nil }
        guard let id = UUID(uuidString: value) else { throw SwitchError.malformed(L10n.tr("Account identity information is incomplete.")) }
        return id.uuidString.lowercased()
    }
    public func signedIn() -> Bool? { LoginProbe.signedIn(cookies: desktop.appendingPathComponent("Cookies")) }
    public func currentAccount() throws -> String {
        guard let value = try SafeFiles.json(desktop.appendingPathComponent("config.json"))["lastKnownAccountUuid"].string,
              let id = UUID(uuidString: value) else { throw SwitchError.missing(L10n.tr("Could not find the current Desktop login.")) }
        return id.uuidString.lowercased()
    }
}

public func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// Claude upgrades the data of an older version when it updates itself, so a login saved by an older Claude
/// can be restored. One saved by a newer Claude may hold formats the installed app cannot read.
public enum DesktopVersion {
    public static func canRestore(saved: String, installed: String) -> Bool {
        if saved == installed { return true }
        guard let saved = parts(saved), let installed = parts(installed) else { return false }
        for index in 0..<max(saved.count, installed.count) {
            let a = index < saved.count ? saved[index] : 0, b = index < installed.count ? installed[index] : 0
            if a != b { return a < b }
        }
        return true
    }
    private static func parts(_ version: String) -> [Int]? {
        let fields = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(fields.count) else { return nil }
        var result: [Int] = []
        for field in fields {
            guard !field.isEmpty, field.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(field) else { return nil }
            result.append(value)
        }
        return result
    }
}

public enum IdentitySchema {
    public static let configKeys: Set<String> = ["lastKnownAccountUuid", "oauth:tokenCache", "oauth:tokenCacheV2"]
    public static let containers = ["Cookies", "Cookies-journal", "Cookies-wal", "Cookies-shm",
                                    "Local Storage", "Session Storage", "IndexedDB"]
    public static func fingerprint(_ config: JSONValue) throws -> String {
        let auth = (config.object ?? [:]).filter { configKeys.contains($0.key) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return digest(try encoder.encode(JSONValue.object(auth)))
    }
    public static func validateConfig(_ value: JSONValue) throws {
        guard let keys = value.object?.keys,
              value["lastKnownAccountUuid"].string.flatMap(UUID.init(uuidString:)) != nil,
              value["oauth:tokenCache"].string != nil || value["oauth:tokenCacheV2"].string != nil else {
            throw SwitchError.malformed(L10n.tr("The current login is incomplete. No snapshot will be saved or overwritten."))
        }
        guard !keys.contains(where: { $0.hasPrefix("oauth:") && !configKeys.contains($0) }) else {
            throw SwitchError.blocked(L10n.tr("A new OAuth storage format was found. Update the adapter before switching."))
        }
    }
}
