import Foundation
import Security
import CommonCrypto
import SwitchCore
import SwitchStorage

/// Only the selected access token is retained; this reader never uses a refresh grant.
struct DesktopAccessToken {
    let value: String
    let accountID: String
    let credentialDigest: String
    let expiresAt: Date
    let organizationID: String
    var tokenDigest: String { digest(Data(value.utf8)) }
    var quotaScope: String { digest(Data((accountID + ":" + organizationID).utf8)) }
}
enum DesktopTokenReader {
    static let access = KeychainKeyCache()
    private struct DecryptionFailure: Error {}
    static func read(environment: MacEnvironment, expectedAccount: String, allowPrompt: Bool) throws -> DesktopAccessToken {
        let config = try environment.liveConfig()
        return try read(config: config, expectedAccount: expectedAccount, allowPrompt: allowPrompt)
    }
    static func read(config: JSONValue, expectedAccount: String, allowPrompt: Bool) throws -> DesktopAccessToken {
        try read(config: config, expectedAccount: expectedAccount, allowPrompt: allowPrompt, access: access, load: safeStorageKey)
    }
    static func read(config: JSONValue, expectedAccount: String, allowPrompt: Bool,
                     access: KeychainKeyCache, load: (Bool) throws -> Data) throws -> DesktopAccessToken {
        let credential = try IdentitySchema.fingerprint(config)
        let unreadable = SwitchError.blocked(L10n.tr("Could not read login data. Update Claude Switch and try again."))
        var usedKey: KeychainKeyCache.Key?
        do {
            return try read(config: config, expectedAccount: expectedAccount) {
                let key = try access.key(allowPrompt: allowPrompt, load: load)
                guard !access.rejects(credential, using: key) else { throw unreadable }
                usedKey = key
                return key.data
            }
        } catch is DecryptionFailure {
            guard let usedKey else { throw unreadable }
            // A freshly authorized key is authoritative; a bad snapshot cannot revoke it.
            if usedKey.freshlyRead {
                access.reject(credential, using: usedKey)
                throw unreadable
            }
            let replacement = try access.key(allowPrompt: allowPrompt, replacing: usedKey, load: load)
            do {
                return try read(config: config, expectedAccount: expectedAccount) { replacement.data }
            } catch is DecryptionFailure {
                access.reject(credential, using: replacement)
                throw unreadable
            }
        }
    }
    static func authorize(allowPrompt: Bool) throws -> Data {
        try access.read(allowPrompt: allowPrompt, load: safeStorageKey)
    }
    /// Saved logins use the same encrypted cache, without restoring anything into Claude's folder.
    static func read(config: JSONValue, expectedAccount: String, password: () throws -> Data) throws -> DesktopAccessToken {
        try IdentitySchema.validateConfig(config)
        guard config["lastKnownAccountUuid"].string?.lowercased() == expectedAccount else {
            throw UsageNotReady(message: SwitchError.changed.localizedDescription)
        }
        guard let encoded = config["oauth:tokenCacheV2"].string ?? config["oauth:tokenCache"].string,
              let encrypted = Data(base64Encoded: encoded), encrypted.prefix(3) == Data("v10".utf8) else {
            throw UsageFailure.invalidCredentials
        }
        var password = try password()
        defer { password.resetBytes(in: 0..<password.count) }
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let derive = key.withUnsafeMutableBytes { output in
            password.withUnsafeBytes { secret in salt.withUnsafeBytes { salt in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), secret.bindMemory(to: Int8.self).baseAddress,
                    password.count, salt.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                    output.bindMemory(to: UInt8.self).baseAddress, kCCKeySizeAES128)
            } }
        }
        guard derive == kCCSuccess else { throw SwitchError.blocked(L10n.tr("Could not read this account's login. Please check the login in Claude.")) }
        defer { key.resetBytes(in: 0..<key.count) }
        let cipher = encrypted.dropFirst(3), iv = Data(repeating: 0x20, count: 16)
        var plain = Data(count: cipher.count + 16), written = 0
        defer { plain.resetBytes(in: 0..<plain.count) }
        let capacity = plain.count
        let status = plain.withUnsafeMutableBytes { out in cipher.withUnsafeBytes { input in
            key.withUnsafeBytes { key in iv.withUnsafeBytes { iv in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        key.baseAddress, key.count, iv.baseAddress, input.baseAddress, input.count,
                        out.baseAddress, capacity, &written)
            } }
        } }
        guard status == kCCSuccess else { throw DecryptionFailure() }
        plain.count = written
        guard let cache = try? JSONDecoder().decode(JSONValue.self, from: plain), cache.object != nil else {
            throw DecryptionFailure()
        }
        let fingerprint = try IdentitySchema.fingerprint(config)
        let entries = (cache.object ?? [:]).compactMap { key, entry -> (key: String, org: String, entry: JSONValue)? in
            guard let org = usageOrganization(cacheKey: key, account: expectedAccount) else { return nil }
            return (key, org, entry)
        }
        guard !entries.isEmpty else { throw UsageFailure.missingScopes }
        guard Set(entries.map(\.org)).count == 1 else {
            throw UsageFailure.ambiguousCredentials
        }
        let bound = entries.filter { $0.key.hasPrefix("acct:") }
        let owned = bound.isEmpty ? entries : bound
        var candidates: [(token: DesktopAccessToken, rank: Int)] = []
        var expired = false, expiring = false, malformed = false
        for item in owned {
            guard let value = item.entry["token"].string, !value.isEmpty else { malformed = true; continue }
            guard let expiry = Dates.parse(item.entry["expiresAt"]) else { malformed = true; continue }
            if expiry <= Date() { expired = true; continue }
            if expiry <= Date().addingTimeInterval(60) { expiring = true; continue }
            candidates.append((DesktopAccessToken(value: value, accountID: expectedAccount, credentialDigest: fingerprint,
                                                  expiresAt: expiry, organizationID: item.org),
                               item.key.contains("user:sessions:claude_code") ? 1 : 0))
        }
        guard let rank = candidates.map(\.rank).min() else {
            if malformed { throw UsageFailure.invalidCredentials }
            if expiring { throw UsageNotReady(reason: .expiring) }
            if expired { throw UsageNotReady(reason: .expired) }
            throw UsageNotReady(reason: .updating)
        }
        let selected = candidates.filter { $0.rank == rank }
        guard Set(selected.map { $0.token.tokenDigest }).count == 1,
              let token = selected.map(\.token).min(by: { $0.expiresAt < $1.expiresAt }) else {
            throw UsageFailure.ambiguousCredentials
        }
        return token
    }

    /// The organization of a token-cache entry that can read usage for `account`, or nil.
    /// Keys read `<client>:<org>:<audience>:<scopes>`, or `acct:<account>|<client>:<org>:…` once Desktop binds them to an account.
    static func usageOrganization(cacheKey: String, account: String) -> String? {
        var key = cacheKey
        if key.hasPrefix("acct:") {
            let parts = key.dropFirst(5).split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].lowercased() == account.lowercased() else { return nil }
            key = String(parts[1])
        }
        let parts = key.components(separatedBy: ":https://api.anthropic.com:")
        guard parts.count == 2 else { return nil }
        let identity = parts[0].split(separator: ":", omittingEmptySubsequences: false)
        let scopes = Set(parts[1].split(separator: " ").map(String.init))
        let allowed: Set<String> = ["user:profile", "user:inference", "user:file_upload", "user:sessions:claude_code", "user:plugins"]
        guard identity.count == 2, identity[0].lowercased() == DesktopUsageProtocol.clientID,
              scopes.isSuperset(of: ["user:profile", "user:inference"]), scopes.isSubset(of: allowed) else { return nil }
        return UUID(uuidString: String(identity[1]))?.uuidString.lowercased()
    }

    /// Claude's own encryption key, which only Claude is trusted to read until the user approves Switch once.
    /// Reads are silent; only a user-requested refresh may show macOS's approval prompt.
    private static func safeStorageKey(allowPrompt: Bool) throws -> Data {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage", kSecAttrAccount as String: "Claude Key",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        let result = KeychainInteraction.shared.perform(allowPrompt: allowPrompt) { interactive in
            if interactive { query.removeValue(forKey: kSecUseAuthenticationUI as String) }
            var value: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &value)
            return .init(status, data: value as? Data)
        }
        guard result.status == errSecSuccess, let password = result.data else {
            throw UsageFailure.keychain
        }
        return password
    }
}
