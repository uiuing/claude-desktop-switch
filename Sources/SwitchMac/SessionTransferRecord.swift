import Foundation
import SwitchCore

enum SessionTransferRecord {
    // Only evidenced identity, authority and live bindings are excluded. Ordinary and future
    // metadata remain intact, including artifacts, task descriptions, lineage and local settings.
    static let excludedFields: Set<String> = [
        "emailAddress", "accountId", "accountUuid", "organizationId", "organizationUuid", "envScopeId",
        "bridgeSessionIds", "remoteControlSpawn", "remoteControlLiveAtUpdateQuit", "sshRemoteProcessId", "sshReattach",
        "chromePermissionMode", "chromeAllowedDomains", "cuAllowedApps", "cuGrantFlags", "cuFlagsGrantedAt",
        "alwaysAllowedReasons"
    ]

    static func data(from record: [String: Any]) throws -> Data {
        var transferred = record
        let excluded = Set(excludedFields.map(normalized))
        for field in record.keys where excluded.contains(normalized(field)) || credentialKeys.contains(normalized(field)) { transferred.removeValue(forKey: field) }
        if let updates = record["sessionPermissionUpdates"] {
            guard let values = updates as? [[String: Any]] else { throw authorizationFormat }
            var retained: [[String: Any]] = []
            for value in values {
                switch value["type"] as? String {
                case "addDirectories", "removeDirectories":
                    guard let directories = value["directories"] as? [String],
                          directories.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else { throw authorizationFormat }
                    retained.append(value)
                case "addRules", "replaceRules", "removeRules", "setMode": break
                default: throw authorizationFormat
                }
            }
            transferred["sessionPermissionUpdates"] = retained
        }
        for field in ["remoteMcpServersConfig", "sshConfig"] {
            if let configuration = record[field] {
                guard configuration is [String: Any] else { throw authorizationFormat }
                guard var clean = try withoutCredentials(configuration) as? [String: Any] else { throw authorizationFormat }
                if field == "sshConfig" {
                    for key in clean.keys where ["identityfile", "identityagent", "sshauthsock"].contains(normalized(key)) { clean.removeValue(forKey: key) }
                }
                transferred[field] = clean
            }
        }
        return try JSONSerialization.data(withJSONObject: transferred, options: .sortedKeys)
    }

    /// Called only after the exact pre-quit check and confirmed shutdown. These are the identities
    /// of the selected graph, not a whitelist of the metadata to save from its final snapshot.
    static func sameIdentity(_ prepared: Data, as record: [String: Any]) throws -> Bool {
        guard let before = try JSONSerialization.jsonObject(with: prepared) as? [String: Any] else { return false }
        for field in ["sessionId", "cliSessionId", "cwd", "worktreePath", "spawnedFrom", "forkedFromSessionId", "lineageDetached"] {
            let lhs = before[field] ?? NSNull(), rhs = record[field] ?? NSNull()
            if !(NSDictionary(dictionary: ["value": lhs]).isEqual(to: ["value": rhs])) { return false }
        }
        return true
    }

    // Inspect keys only in the credential-bearing connector container. Message bodies and opaque
    // task metadata must never be scrubbed merely because they contain words such as "token".
    private static let credentialKeys: Set<String> = [
        "authorization", "proxyauthorization", "cookie", "cookies", "setcookie", "token", "accesstoken",
        "refreshtoken", "idtoken", "sessionkey", "apikey", "xapikey", "password", "clientsecret",
        "credentials", "authentication", "auth", "privatekey"
    ]
    static func withoutCredentials(_ value: Any) throws -> Any {
        if let fields = value as? [String: Any] {
            return try fields.reduce(into: [String: Any]()) { result, item in
                let key = normalized(item.key)
                guard !credentialKey(item.key) else { return }
                if ["url", "endpoint"].contains(key), let text = item.value as? String,
                   let url = URLComponents(string: text),
                   url.user != nil || url.password != nil || (url.queryItems ?? []).contains(where: { credentialKey($0.name) }) {
                    throw authorizationFormat
                }
                result[item.key] = try withoutCredentials(item.value)
            }
        }
        if let values = value as? [Any] { return try values.map(withoutCredentials) }
        return value
    }
    private static func credentialKey(_ field: String) -> Bool {
        let key = normalized(field), words = field.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return credentialKeys.contains(key) || ["token", "secret", "password", "privatekey", "apikey", "accesskey"].contains(where: key.hasSuffix) ||
            words.contains(where: { ["token", "secret", "password", "credential", "credentials", "authorization", "auth"].contains(String($0)) }) ||
            (words.contains("key") && (words.contains("api") || words.contains("access")))
    }
    private static func normalized(_ key: String) -> String { key.lowercased().filter { $0.isLetter || $0.isNumber } }
    private static var authorizationFormat: SwitchError {
        .blocked(L10n.tr("This conversation has an unsupported authorization format. Its original data is unchanged."))
    }
}
