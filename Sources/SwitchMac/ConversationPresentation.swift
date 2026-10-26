import Foundation
import SwitchCore
import SwitchStorage

/// Code history is shared by local logins. Its persisted presentation must survive each login swap
/// too, including conversations transferred separately before that swap. Authentication stays target-owned.
enum ConversationPresentation {
    static let prefix = "Local Storage/leveldb/"
    static let pane = "epitaxy.sidePaneStore.v1"
    // Storage ownership boundaries, not a field whitelist. New fields within each store are opaque.
    static let stores: Set<String> = [pane, "epitaxy.terminalTabs.v1", "epitaxy.terminalPromptLines.v1",
                                      "epitaxy.sessionPaneScroll.v1", "epitaxy.sideChat.v1"]

    static func relative(_ session: Conversation, target: Account) throws -> String {
        let record = try MigrationBuilder.destinationRelative(session: session, target: target)
        return String(record.dropLast((session.sessionID + ".json").count)) + "switch-presentation/" + session.sessionID + ".json"
    }

    /// A credential-free, conversation-owned snapshot also covers transfers performed before login
    /// switching. It has the lifetime of the conversation, not the login recovery archive.
    struct Saved: Codable { var format = 1; var sessionID: String; var cliSessionID: String; var files: [ArchiveFile] }
    /// Reuse an old CLI label only when stable session scoping preserves the entire keyspace.
    /// A reference to the previous engine or any lost state leaves the binding ambiguous.
    static func canRebind(_ saved: Saved, session: Conversation) throws -> Bool {
        guard saved.format == 1, saved.sessionID == session.sessionID,
              saved.files.allSatisfy({ $0.path.hasPrefix(prefix) }), UUID(uuidString: saved.cliSessionID) != nil,
              session.cliSessionID.flatMap(UUID.init(uuidString:)) != nil,
              let original = try database(saved.files) else { return false }
        let previousID = saved.cliSessionID.lowercased()
        for (key, value) in original {
            guard let zero = key.firstIndex(of: 0) else { return false }
            let name = try decode(Data(key.suffix(from: zero + 1)))
            guard !name.lowercased().contains(previousID),
                  !(try decode(value)).lowercased().contains(previousID) else { return false }
        }
        let empty = try LevelDBSnapshot.files([:]).map { ArchiveFile(path: prefix + $0.key, data: $0.value, sha256: digest($0.value)) }
        let target = LoginSnapshot(accountID: "", version: "", createdAt: .distantPast, auth: [:], files: empty,
                                   directories: ["Local Storage", "Local Storage/leveldb"])
        let scoped = try merge(source: saved.files, target: target, ids: [session.sessionID])
        return try database(scoped.files) == original
    }

    private static func database(_ files: [ArchiveFile]) throws -> [Data: Data]? {
        let selected = files.filter { $0.path.hasPrefix(prefix) }
        guard !selected.isEmpty else { return nil }
        var data: [String: Data] = [:]
        for file in selected {
            let name = String(file.path.dropFirst(prefix.count))
            guard !name.contains("/"), data[name] == nil, digest(file.data) == file.sha256 else { throw SwitchError.changed }
            data[name] = file.data
        }
        return try LevelDBSnapshot.read(data)
    }
    static func saved(_ data: Data, session: Conversation) throws -> [ArchiveFile] {
        let value = try JSONDecoder().decode(Saved.self, from: data)
        guard value.format == 1 else { throw invalid(check: .format) }
        guard value.sessionID == session.sessionID else { throw invalid(check: .sessionIdentity) }
        guard value.files.allSatisfy({ $0.path.hasPrefix(prefix) }) else { throw invalid(check: .filePath) }
        guard value.files.allSatisfy({ digest($0.data) == $0.sha256 }) else { throw invalid(check: .fileDigest) }
        if value.cliSessionID != session.cliSessionID {
            guard try canRebind(value, session: session) else { throw invalid(check: .historyBinding) }
            Task { await RuntimeLog.shared.record(.bindingReused, component: .storage, source: .conversationPresentation, check: .historyBinding) }
        }
        return value.files
    }
    static func changes(sessions: [Conversation], sources: [String: [[ArchiveFile]]], target: Account,
                        environment: MacEnvironment, expectations: [String: FileExpectation]) throws -> [MigrationChange] {
        var changes: [MigrationChange] = []
        for session in sessions {
            guard let cli = session.cliSessionID else { throw invalid() }
            let relative = try relative(session, target: target)
            guard let expected = expectations["presentation:" + relative],
                  try ConversationResources.fingerprint(SafeFiles.child(relative, of: environment.desktop)) == expected else { throw SwitchError.changed }
            let empty = try LevelDBSnapshot.files([:]).map { ArchiveFile(path: prefix + $0.key, data: $0.value, sha256: digest($0.value)) }
            var snapshot = LoginSnapshot(accountID: target.id, version: "", createdAt: Date(), auth: [:], files: empty,
                                         directories: ["Local Storage", "Local Storage/leveldb"])
            let sourceAccount = Account(id: session.accountID, organizationID: session.organizationID)
            let previous = try SafeFiles.child(Self.relative(session, target: sourceAccount), of: environment.desktop)
            if FileManager.default.fileExists(atPath: previous.path) {
                snapshot = try merge(source: saved(SafeFiles.read(previous, limit: 64 * 1024 * 1024), session: session), target: snapshot, ids: [session.sessionID, cli])
            }
            for source in sources[session.accountID] ?? [] {
                snapshot = try merge(source: source, target: snapshot, ids: [session.sessionID, cli])
            }
            let database = Dictionary(uniqueKeysWithValues: snapshot.files.map { (String($0.path.dropFirst(prefix.count)), $0.data) })
            if try LevelDBSnapshot.read(database).isEmpty { continue }
            let data = try JSONEncoder().encode(Saved(sessionID: session.sessionID, cliSessionID: cli, files: snapshot.files))
            guard data.count <= 64 * 1024 * 1024 else { throw invalid() }
            changes.append(MigrationChange(relative: relative, data: data, expectation: expected))
        }
        return changes
    }
    static func restoring(_ target: LoginSnapshot, sessions: [Conversation], changes: [MigrationChange],
                          environment: MacEnvironment) throws -> LoginSnapshot {
        var result = target
        let account = Account(id: target.accountID, organizationID: sessions.first?.organizationID)
        for session in sessions {
            let path = try relative(session, target: account)
            let prepared = changes.first { $0.relative == path }?.data
            let file = try SafeFiles.child(path, of: environment.desktop)
            if prepared != nil || FileManager.default.fileExists(atPath: file.path) {
                let data = try prepared ?? SafeFiles.read(file, limit: 64 * 1024 * 1024)
                result = try merge(source: saved(data, session: session), target: result,
                                   ids: Set([session.sessionID] + (session.cliSessionID.map { [$0] } ?? [])))
            }
        }
        return result
    }

    static func localIDs(environment: MacEnvironment) throws -> Set<String> {
        let root = environment.desktop.appendingPathComponent("claude-code-sessions")
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        var ids = Set<String>()
        for account in try SafeFiles.strictChildren(root) where UUID(uuidString: account.lastPathComponent) != nil {
            guard try account.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw SwitchError.unsafePath }
            for org in try SafeFiles.strictChildren(account) where UUID(uuidString: org.lastPathComponent) != nil {
                let records = try ConversationRecords.readScope(desktop: environment.desktop,
                    accountID: account.lastPathComponent, organizationID: org.lastPathComponent)
                ids.formUnion(records.flatMap { [$0.sessionID] + ($0.cliSessionID.map { [$0] } ?? []) })
                guard ids.count <= 20_000 else { throw invalid() }
            }
        }
        return ids
    }

    static func merge(source: [ArchiveFile], target: LoginSnapshot, ids: Set<String>) throws -> LoginSnapshot {
        guard !ids.isEmpty else { return target }
        guard let original = try database(source) else { return target }
        let candidates = try original.compactMap { key, value -> (Data, String, Data, Data)? in
            guard key.first == 95, let zero = key.firstIndex(of: 0) else { return nil }
            let name = try decode(Data(key.suffix(from: zero + 1)))
            guard stores.contains(name) || name.hasPrefix(pane + ".pane.") else { return nil }
            return (key, name, Data(key.prefix(through: zero)), value)
        }
        guard !candidates.isEmpty else { return target }
        guard var destination = try database(target.files) else { throw invalid() }
        var changed = false
        for (sourceKey, name, origin, value) in candidates {
            let targetKeys = try destination.keys.filter {
                guard $0.starts(with: origin) else { return false }
                return try decode(Data($0.dropFirst(origin.count))) == name
            }
            guard targetKeys.count <= 1 else { throw invalid() }
            let key = targetKeys.first ?? sourceKey
            let old = try destination[key].map(json) ?? [:], incoming = try json(value)
            let merged = try mergeStore(incoming, into: old, ids: ids)
            guard !NSDictionary(dictionary: old).isEqual(to: merged) else { continue }
            let text = String(decoding: try JSONSerialization.data(withJSONObject: merged, options: .sortedKeys), as: UTF8.self)
            destination[key] = encode(text); changed = true
        }
        guard changed else { return target }
        // Chromium derives origin byte usage from encoded keys (without the origin prefix) and values.
        // Keep metadata and unknown fields intact; patch only the protobuf size field where present.
        for origin in Set(candidates.map { $0.2 }) {
            let serializedOrigin = Data(origin.dropFirst().dropLast())
            let size = destination.filter { $0.key.starts(with: origin) }.reduce(0) { $0 + $1.key.count - origin.count + $1.value.count }
            for name in ["META:", "METAWRITE:"] {
                let key = Data(name.utf8) + serializedOrigin
                if let data = destination[key] { destination[key] = try metadata(data, size: UInt64(size)) }
            }
        }
        let files = try LevelDBSnapshot.files(destination)
        guard try LevelDBSnapshot.read(files) == destination else { throw invalid() }
        var result = target
        result.files.removeAll { $0.path.hasPrefix(prefix) }
        result.files += files.map { ArchiveFile(path: prefix + $0.key, data: $0.value, sha256: digest($0.value)) }
        result.directories = Array(Set(result.directories + ["Local Storage", "Local Storage/leveldb"])).sorted()
        return result
    }

    static func mergeStore(_ source: [String: Any], into target: [String: Any], ids: Set<String>) throws -> [String: Any] {
        let sourceState = source["state"] as? [String: Any] ?? source
        let targetState = target["state"] as? [String: Any] ?? target
        let current = (sourceState["currentSessionId"] as? String).map { ids.contains($0) } ?? false
        var selected = scoped(sourceState, ids: ids)
        if current {
            // The live pane snapshot belongs to currentSessionId. Preserve future fields as a unit.
            selected = sourceState
            for (key, value) in sourceState {
                if (key.hasSuffix("BySession") || key == "bySession"), let map = value as? [String: Any] {
                    selected[key] = map.filter { ids.contains($0.key) }
                }
            }
        }
        guard !selected.isEmpty else { return target }
        if let oldVersion = target["version"], let newVersion = source["version"],
           !NSDictionary(dictionary: ["v": oldVersion]).isEqual(to: ["v": newVersion]) { throw invalid() }
        guard let clean = try SessionTransferRecord.withoutCredentials(selected) as? [String: Any] else { throw invalid() }
        let state = overlay(clean, onto: targetState)
        guard source["state"] != nil else { return state }
        var merged = target
        // Envelope metadata is retained too; its version is a representation boundary, not a field gate.
        guard let envelope = try SessionTransferRecord.withoutCredentials(source) as? [String: Any] else { throw invalid() }
        for (key, value) in envelope where key != "state" { merged[key] = value }
        merged["state"] = state
        return merged
    }
    private static func scoped(_ source: [String: Any], ids: Set<String>) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in source {
            if ids.contains(key) { result[key] = value }
            else if let nested = value as? [String: Any] {
                let selected = scoped(nested, ids: ids)
                if !selected.isEmpty { result[key] = selected }
            }
        }
        return result
    }
    private static func overlay(_ source: [String: Any], onto target: [String: Any]) -> [String: Any] {
        var result = target
        for (key, value) in source {
            if let map = value as? [String: Any], let old = target[key] as? [String: Any], !LocalID.isSession(key) {
                result[key] = overlay(map, onto: old)
            } else { result[key] = value }
        }
        return result
    }
    static func decode(_ data: Data) throws -> String {
        guard let type = data.first, type <= 1,
              let value = String(data: data.dropFirst(), encoding: type == 0 ? .utf16LittleEndian : .isoLatin1) else { throw invalid() }
        return value
    }
    static func encode(_ text: String) -> Data { Data([0]) + text.data(using: .utf16LittleEndian)! }
    private static func json(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(decode(data).utf8)) as? [String: Any] else { throw invalid() }
        return object
    }
    private static func metadata(_ data: Data, size: UInt64) throws -> Data {
        var offset = 0, result = Data(), replaced = false
        func read() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard offset < data.count else { throw invalid() }
                let byte = data[offset]; offset += 1
                guard shift < 63 || byte <= 1 else { throw invalid() }
                value |= UInt64(byte & 127) << shift
                if byte < 128 { return value }
            }
            throw invalid()
        }
        func varint(_ value: UInt64) -> Data {
            var value = value, bytes = Data()
            while value >= 128 { bytes.append(UInt8(value & 127) | 128); value >>= 7 }
            bytes.append(UInt8(value)); return bytes
        }
        while offset < data.count {
            let start = offset, tag = try read()
            switch tag & 7 {
            case 0: _ = try read()
            case 1: offset += 8
            case 2:
                let length = try read(); guard length <= data.count else { throw invalid() }; offset += Int(length)
            case 5: offset += 4
            default: throw invalid()
            }
            guard offset <= data.count else { throw invalid() }
            if tag == 16 { result += Data([16]) + varint(size); replaced = true }
            else { result += data[start..<offset] }
        }
        if !replaced { result += Data([16]) + varint(size) }
        return result
    }
    private static func invalid(check: RuntimeLog.Check = .representation, line: UInt = #line) -> SwitchError {
        RuntimeLog.validation(.conversationPresentation, check: check, line: line)
        return .blocked(L10n.tr("The conversation history could not be verified. Its original data is unchanged."))
    }
}
