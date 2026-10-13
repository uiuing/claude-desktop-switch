import Foundation
import Security
import CommonCrypto
import SwitchCore
import SwitchStorage

/// Only instantiated by an explicit live-usage action. Refresh tokens never leave the encrypted cache.
struct DesktopAccessToken {
    let value: String
    let accountID: String
    let credentialDigest: String
    let expiresAt: Date
    let organizationID: String
}
enum DesktopTokenReader {
    static func read(environment: MacEnvironment, expectedAccount: String, allowPrompt: Bool) throws -> DesktopAccessToken {
        let bytes = try SafeFiles.read(environment.desktop.appendingPathComponent("config.json"))
        let config = try JSONDecoder().decode(JSONValue.self, from: bytes)
        guard config["lastKnownAccountUuid"].string?.lowercased() == expectedAccount else {
            throw UsageNotReady(message: SwitchError.changed.localizedDescription)
        }
        guard let encoded = config["oauth:tokenCacheV2"].string ?? config["oauth:tokenCache"].string,
              let encrypted = Data(base64Encoded: encoded), encrypted.prefix(3) == Data("v10".utf8) else {
            throw SwitchError.blocked(L10n.tr("This Desktop login encryption format is unsupported, so live quota can't be fetched. Showing usage read on this Mac with an inferred reset time."))
        }
        let password = try safeStorageKey(allowPrompt: allowPrompt)
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
        let cache = try JSONDecoder().decode(JSONValue.self, from: plain)
        let fingerprint = try IdentitySchema.fingerprint(config)
        let candidates = (cache.object ?? [:]).compactMap { composite, entry -> DesktopAccessToken? in
            guard let org = usageOrganization(cacheKey: composite, account: expectedAccount),
                  let token = entry["token"].string, !token.isEmpty,
                  let expiry = Dates.parse(entry["expiresAt"]), expiry > Date().addingTimeInterval(60) else { return nil }
            return DesktopAccessToken(value: token, accountID: expectedAccount, credentialDigest: fingerprint, expiresAt: expiry,
                                      organizationID: org)
        }
        guard Set(candidates.map(\.organizationID)).count <= 1 else {
            throw SwitchError.blocked(L10n.tr("The login cache contains multiple organizations and can't be attributed. Showing usage read on this Mac with an inferred reset time."))
        }
        guard let token = candidates.max(by: { $0.expiresAt < $1.expiresAt }) else {
            throw UsageNotReady(message: L10n.tr("The access token has expired. Let Claude update the login; Switch does not use refresh tokens."))
        }
        return token
    }

    /// The organization of a token-cache entry that can read usage for `account`, or nil.
    /// Keys read `<client>:<org>:<audience>:<scopes>`, or `acct:<account>|<client>:<org>:…` once Desktop binds them to an account.
    static func usageOrganization(cacheKey: String, account: String) -> String? {
        guard let boundary = cacheKey.range(of: "https://api.anthropic.com:") else { return nil }
        let scopes = cacheKey[boundary.upperBound...].split(separator: " ")
        guard scopes.contains("user:profile"), scopes.contains("user:inference") else { return nil }
        let prefix = cacheKey[..<boundary.lowerBound].split(separator: ":")
        switch prefix.count {
        case 2: break
        case 3 where prefix[0] == "acct":
            guard prefix[1].split(separator: "|").first?.lowercased() == account.lowercased() else { return nil }
        default: return nil
        }
        return UUID(uuidString: String(prefix[prefix.count - 1]))?.uuidString.lowercased()
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
            throw SwitchError.blocked(L10n.tr("Silent Keychain access can't be guaranteed, so live quota won't be fetched. Showing usage read on this Mac with an inferred reset time."))
        }
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        SecKeychainSetUserInteractionAllowed(old.boolValue)
        if status != errSecSuccess && allowPrompt {
            query.removeValue(forKey: kSecUseAuthenticationUI as String)
            SecKeychainSetUserInteractionAllowed(true)
            status = SecItemCopyMatching(query as CFDictionary, &result)
            SecKeychainSetUserInteractionAllowed(old.boolValue)
            if status == errSecUserCanceled || status == errSecAuthFailed {
                throw SwitchError.blocked(L10n.tr("Claude Switch isn't allowed to read Claude Safe Storage, so live quota can't be fetched. Showing usage read on this Mac with an inferred reset time."))
            }
        }
        guard status == errSecSuccess, let password = result as? Data else {
            throw SwitchError.blocked(L10n.tr("Allow Claude Switch to read Claude Safe Storage: click Refresh, enter your login password in the system prompt, and choose “Always Allow”."))
        }
        return password
    }
}
