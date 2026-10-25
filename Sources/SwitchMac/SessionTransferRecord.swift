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
        guard var transferred = try withoutCredentials(record.filter { !["remoteMcpServersConfig", "sshConfig"].contains($0.key) }) as? [String: Any] else { throw authorizationFormat }
        for key in ["remoteMcpServersConfig", "sshConfig"] where record[key] is NSNull { transferred[key] = NSNull() }
        let excluded = Set(excludedFields.map(normalized))
        for field in record.keys where excluded.contains(normalized(field)) || credentialKeys.contains(normalized(field)) { transferred.removeValue(forKey: field) }
        if let updates = record["sessionPermissionUpdates"], !(updates is NSNull) {
            guard let values = updates as? [[String: Any]] else { throw authorizationFormat }
            var retained: [[String: Any]] = []
            for value in values {
                switch value["type"] as? String {
                case "addDirectories", "removeDirectories":
                    guard let directories = value["directories"] as? [String],
                          directories.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else { throw authorizationFormat }
                    guard let clean = try withoutCredentials(value) as? [String: Any] else { throw authorizationFormat }
                    retained.append(clean)
                case "addRules", "replaceRules", "removeRules", "setMode": break
                default: throw authorizationFormat
                }
            }
            transferred["sessionPermissionUpdates"] = retained
        }
        if let configuration = record["remoteMcpServersConfig"], !(configuration is NSNull) {
            // Desktop persists a server catalog array; retain legacy object-shaped configuration too.
            guard configuration is [[String: Any]] || configuration is [String: Any] else { throw authorizationFormat }
            transferred["remoteMcpServersConfig"] = try clean(configuration, context: .connection)
        }
        if let configuration = record["sshConfig"], !(configuration is NSNull) {
            guard let fields = configuration as? [String: Any],
                  var clean = try clean(fields, context: .connection) as? [String: Any] else { throw authorizationFormat }
            for key in clean.keys where ["identityfile", "identityagent", "sshauthsock"].contains(normalized(key)) { clean.removeValue(forKey: key) }
            transferred["sshConfig"] = clean
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

    // Generic terms such as token/auth are meaningful only inside an authentication boundary.
    // Explicit bearer/access credentials are excluded from structured metadata at any depth.
    private static let credentialKeys: Set<String> = [
        "authorization", "proxyauthorization", "cookie", "cookies", "setcookie", "token", "accesstoken",
        "refreshtoken", "idtoken", "sessionkey", "apikey", "xapikey", "password", "clientsecret",
        "credentials", "authentication", "auth", "privatekey"
    ]
    private static let explicitCredentials = credentialKeys.subtracting(["token", "authorization", "auth", "authentication"])
        .union(["bearertoken", "oauthtoken", "oauthaccesstoken", "oauthrefreshtoken", "credentialpayload"])
    private enum Context { case metadata, connection, authentication }

    static func withoutCredentials(_ value: Any) throws -> Any { try clean(value, context: .metadata) }

    private static func clean(_ value: Any, context: Context, tool: Bool = false) throws -> Any {
        if let fields = value as? [String: Any] {
            // Header arrays can encode credentials as {name, value} pairs instead of object keys.
            if context == .authentication, let name = (fields["name"] ?? fields["key"]) as? String, credentialKey(name) { return NSNull() }
            return try fields.reduce(into: [String: Any]()) { result, item in
                let key = normalized(item.key)
                guard !(context == .authentication ? credentialKey(item.key) :
                    explicitCredentials.contains(key) || (context == .connection && credentialKeys.contains(key))) else { return }
                if ["auth", "authorization"].contains(key), let text = item.value as? String,
                   ["bearer ", "basic "].contains(where: text.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix) { return }
                // Only tool descriptor schemas are opaque; a same-named field in auth is not a schema.
                if tool, ["inputschema", "outputschema"].contains(key) {
                    result[item.key] = item.value; return
                }
                if context != .metadata, ["url", "endpoint"].contains(key), let text = item.value as? String,
                   let url = URLComponents(string: text),
                   url.user != nil || url.password != nil || (url.queryItems ?? []).contains(where: { credentialKey($0.name) || ["key", "sig", "signature", "xamzsignature", "xgoogsignature"].contains(normalized($0.name)) }) {
                    throw SwitchError.blocked(L10n.tr("This conversation has credentials in a connection URL. Reauthorize the connection in Claude before transferring."))
                }
                let auth = ["auth", "authentication", "authorization", "credentials", "oauth", "oauthaccount", "headers", "httpheaders", "env"].contains(key)
                let childContext: Context = auth && (item.value is [String: Any] || item.value is [Any]) ? .authentication : context
                if context != .authentication, key == "tools", let tools = item.value as? [[String: Any]] {
                    result[item.key] = try tools.map { try clean($0, context: .metadata, tool: true) }; return
                }
                // Text-bearing history and drafts are payloads, not executable authentication config.
                if context == .metadata, ["message", "messages", "content", "draft", "prompt", "text", "instructions", "description"].contains(key) {
                    result[item.key] = item.value; return
                }
                result[item.key] = try clean(item.value, context: childContext)
            }
        }
        if let values = value as? [Any] {
            if context == .authentication, values.count == 2, let name = values.first as? String, credentialKey(name) { return NSNull() }
            return try values.compactMap { value -> Any? in
                let filtered = try clean(value, context: context)
                return !(value is NSNull) && filtered is NSNull ? nil : filtered
            }
        }
        return value
    }
    private static func credentialKey(_ field: String) -> Bool {
        let key = normalized(field)
        let words = field.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1_$2", options: .regularExpression)
            .lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return credentialKeys.contains(key) || ["token", "secret", "password", "privatekey", "apikey", "accesskey"].contains(where: key.hasSuffix) ||
            words.contains(where: { ["token", "secret", "password", "credential", "credentials", "authorization", "auth"].contains(String($0)) }) ||
            (words.contains("key") && (words.contains("api") || words.contains("access")))
    }
    private static func normalized(_ key: String) -> String { key.lowercased().filter { $0.isLetter || $0.isNumber } }
    private static var authorizationFormat: SwitchError {
        .blocked(L10n.tr("This conversation has an unsupported authorization format. Its original data is unchanged."))
    }
}
