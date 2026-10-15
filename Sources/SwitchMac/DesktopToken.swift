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
    static func read(environment: MacEnvironment, expectedAccount: String, allowPrompt: Bool) throws -> DesktopAccessToken {
        let config = try environment.liveConfig()
        return try read(config: config, expectedAccount: expectedAccount, allowPrompt: allowPrompt)
    }
    static func read(config: JSONValue, expectedAccount: String, allowPrompt: Bool) throws -> DesktopAccessToken {
        try read(config: config, expectedAccount: expectedAccount) { try safeStorageKey(allowPrompt: allowPrompt) }
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
        guard derive == kCCSuccess else { throw SwitchError.blocked(L10n.tr("Could not decrypt the current login cache.")) }
        defer { key.resetBytes(in: 0..<key.count) }
        let cipher = encrypted.dropFirst(3), iv = Data(repeating: 0x20, count: 16)
        var plain = Data(count: cipher.count + 16), written = 0
        let capacity = plain.count
        let status = plain.withUnsafeMutableBytes { out in cipher.withUnsafeBytes { input in
            key.withUnsafeBytes { key in iv.withUnsafeBytes { iv in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        key.baseAddress, key.count, iv.baseAddress, input.baseAddress, input.count,
                        out.baseAddress, capacity, &written)
            } }
        } }
        guard status == kCCSuccess else { throw SwitchError.blocked(L10n.tr("Could not read the login cache. The adapter may need updating.")) }
        plain.count = written; defer { plain.resetBytes(in: 0..<plain.count) }
        guard let cache = try? JSONDecoder().decode(JSONValue.self, from: plain), cache.object != nil else {
            throw UsageFailure.invalidCredentials
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
        var result: CFTypeRef?
        // The process-wide legacy guard covers trusted-app ACLs as well as modern access-control items.
        var old: DarwinBoolean = true
        guard SecKeychainGetUserInteractionAllowed(&old) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
            throw UsageFailure.keychain
        }
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        SecKeychainSetUserInteractionAllowed(old.boolValue)
        if status != errSecSuccess && allowPrompt {
            query.removeValue(forKey: kSecUseAuthenticationUI as String)
            SecKeychainSetUserInteractionAllowed(true)
            status = SecItemCopyMatching(query as CFDictionary, &result)
            SecKeychainSetUserInteractionAllowed(old.boolValue)
            if status == errSecUserCanceled || status == errSecAuthFailed {
                throw UsageFailure.keychain
            }
        }
        guard status == errSecSuccess, let password = result as? Data else {
            throw UsageFailure.keychain
        }
        return password
    }
}
