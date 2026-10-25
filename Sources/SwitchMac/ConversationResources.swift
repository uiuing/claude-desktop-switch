import Foundation
import CryptoKit
import SwitchCore
import SwitchStorage

enum ConversationResources {
    static let maximumBytes = 128 * 1024 * 1024
    static let maximumFiles = 10_000

    /// These are ownership boundaries, not a list of fields or file extensions to retain.
    static func ownedComponent(_ name: String, ids: Set<String>) -> Bool {
        ids.contains { name == $0 || name.hasPrefix($0 + ".") }
    }

    static func isOwnedPath(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[0] == "claude-code-sessions",
              UUID(uuidString: parts[1]) != nil, UUID(uuidString: parts[2]) != nil else { return false }
        return parts.dropFirst(3).contains { LocalID.isSession(String($0.split(separator: ".").first ?? "")) }
    }

    static func fingerprint(_ url: URL) throws -> FileExpectation {
        try SafeFiles.validateAncestors(url)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { return .absent }
        if !directory.boolValue { return .sha256(digest(try SafeFiles.read(url, limit: maximumBytes))) }
        let archive = try contents(url, relative: "resource")
        var hash = SHA256()
        for path in archive.directories.sorted() { hash.update(data: Data(("d\0" + path + "\0").utf8)) }
        for file in archive.files.sorted(by: { $0.path < $1.path }) {
            hash.update(data: Data(("f\0" + file.path + "\0" + file.sha256 + "\0").utf8))
        }
        return .directory(SHA256Digest(hash.finalize()))
    }

    private static func SHA256Digest(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    static func contents(_ root: URL, relative: String) throws -> (files: [ArchiveFile], directories: [String]) {
        var files: [ArchiveFile] = [], directories: [String] = [], bytes = 0
        func visit(_ folder: URL, _ path: String, _ depth: Int) throws {
            guard depth < 32, files.count + directories.count < maximumFiles else { throw tooLarge }
            directories.append(path)
            for file in try SafeFiles.strictChildren(folder).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let next = path + "/" + file.lastPathComponent
                if try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { try visit(file, next, depth + 1) }
                else {
                    let data = try SafeFiles.read(file, limit: maximumBytes - bytes)
                    bytes += data.count
                    guard files.count + directories.count < maximumFiles else { throw tooLarge }
                    files.append(ArchiveFile(path: next, data: data, sha256: digest(data)))
                }
            }
        }
        try visit(root, relative, 0)
        return (files, directories)
    }

    /// Preserve every session-owned companion, including future formats and hidden entries.
    /// Shared account catalogs are not guessed to belong to one selected conversation.
    static func companions(sessions: [Conversation], target: Account, environment: MacEnvironment,
                           trustedTargets: [String: FileExpectation] = [:]) throws -> [MigrationChange] {
        guard !sessions.isEmpty else { return [] }
        guard let targetOrg = target.organizationID else { throw SwitchError.unsafePath }
        var changes: [MigrationChange] = [], removals: [MigrationChange] = [], seen = Set<String>(), bytes = 0
        let scopes = Dictionary(grouping: sessions, by: { $0.accountID + "/" + $0.organizationID })
        for (scope, members) in scopes.sorted(by: { $0.key < $1.key }) {
            let sourcePrefix = "claude-code-sessions/" + scope
            let targetPrefix = "claude-code-sessions/\(target.id)/\(targetOrg)"
            let folder = try SafeFiles.child(sourcePrefix, of: environment.desktop)
            let ids = Set(members.flatMap { [$0.sessionID] + ($0.cliSessionID.map { [$0] } ?? []) })
            var entries = 0
            func visit(_ directory: URL, _ tail: String, _ depth: Int) throws {
                guard depth < 16 else { throw tooLarge }
                for item in try SafeFiles.strictChildren(directory).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    entries += 1
                    guard entries < maximumFiles else { throw tooLarge }
                    let name = item.lastPathComponent, path = tail.isEmpty ? name : tail + "/" + name
                    let isDirectory = try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                    if tail.isEmpty, name.hasSuffix(".json"), LocalID.isSession(String(name.dropLast(5))) { continue }
                    if ownedComponent(name, ids: ids) {
                        let destination = targetPrefix + "/" + path, source = sourcePrefix + "/" + path
                        guard seen.insert(destination).inserted else { throw ConversationTree.unresolved }
                        let expected = try fingerprint(SafeFiles.child(destination, of: environment.desktop))
                        // Resource collisions must not replace unrelated attachments or queues.
                        let sourceState = try fingerprint(item)
                        let presentation = path == "switch-presentation/" + name
                        guard isDirectory || presentation || expected == .absent || expected == sourceState || trustedTargets["target:" + destination] == expected else {
                            throw SwitchError.blocked(L10n.tr("The target account has conflicting conversation resources. Nothing was replaced."))
                        }
                        var change = MigrationChange(relative: destination, data: nil, expectation: expected)
                        change.sourceRelative = source; change.sourceExpectation = sourceState
                        if isDirectory {
                            var archive = try contents(item, relative: destination)
                            if expected != .absent {
                                guard case .directory = expected else { throw SwitchError.changed }
                                let existing = try contents(SafeFiles.child(destination, of: environment.desktop), relative: destination)
                                var files = Dictionary(uniqueKeysWithValues: existing.files.map { ($0.path, $0) })
                                for file in archive.files {
                                    guard files[file.path] == nil || files[file.path]?.sha256 == file.sha256 else {
                                        throw SwitchError.blocked(L10n.tr("The target account has conflicting conversation resources. Nothing was replaced."))
                                    }
                                    files[file.path] = file
                                }
                                archive = (files.values.sorted { $0.path < $1.path }, Array(Set(existing.directories + archive.directories)).sorted())
                            }
                            change.files = archive.files; change.directories = archive.directories
                            bytes += archive.files.reduce(0) { $0 + $1.data.count }
                        } else {
                            change.data = try SafeFiles.read(item, limit: maximumBytes)
                            bytes += change.data?.count ?? 0
                            if path.hasPrefix("waiting-input/"), name.hasSuffix(".json") {
                                try validateQueue(change.data!, at: item, sessionID: String(name.dropLast(5)))
                            }
                        }
                        guard bytes <= maximumBytes else { throw tooLarge }
                        changes.append(change)
                        // A queue manifest must have only one consumer. Keep opaque payloads at their
                        // original paths too, because already-recorded references may still name them.
                        if path.hasPrefix("waiting-input/"), !isDirectory, name.hasSuffix(".json") {
                            removals.append(MigrationChange(relative: source, data: nil, expectation: sourceState))
                        }
                    } else if isDirectory, !LocalID.isSession(name) { try visit(item, path, depth + 1) }
                }
            }
            try visit(folder, "", 0)
            let destinationRoot = try SafeFiles.child(targetPrefix, of: environment.desktop)
            if FileManager.default.fileExists(atPath: destinationRoot.path) {
                func check(_ directory: URL, _ tail: String, _ depth: Int) throws {
                    guard depth < 16 else { throw tooLarge }
                    for item in try SafeFiles.strictChildren(directory) {
                        entries += 1; guard entries < maximumFiles * 2 else { throw tooLarge }
                        let name = item.lastPathComponent, path = tail.isEmpty ? name : tail + "/" + name
                        if tail.isEmpty, name.hasSuffix(".json"), LocalID.isSession(String(name.dropLast(5))) { continue }
                        if ownedComponent(name, ids: ids) {
                            guard !path.hasPrefix("waiting-input/") || seen.contains(targetPrefix + "/" + path) || item.pathExtension != "json" else {
                                throw SwitchError.blocked(L10n.tr("The target account has conflicting conversation resources. Nothing was replaced."))
                            }
                        } else if try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true, !LocalID.isSession(name) {
                            try check(item, path, depth + 1)
                        }
                    }
                }
                try check(destinationRoot, "", 0)
            }
        }
        return changes + removals
    }

    /// Native transcripts and their entire companion directories stay shared and byte-for-byte intact.
    static func retained(sessions: [Conversation], environment: MacEnvironment) throws -> [String: FileExpectation] {
        var result: [String: FileExpectation] = [:]
        // Stable session IDs must not silently reattach the incoming login to a persistent browser
        // credential jar. Claude owns clearing/re-authorizing those mixed stores.
        let config = try environment.effectiveConfig(), partitions = environment.desktop.appendingPathComponent("Partitions")
        let persistent = config["launchPreviewStorage"].string.map { $0 != "none" } ?? false
        let remembered = !(config["launchPreviewPersistedWorkspaces"].array ?? []).isEmpty ||
            !(config["launchPreviewSessionScopedSessions"].array ?? []).isEmpty
        if (persistent || remembered), FileManager.default.fileExists(atPath: partitions.path),
           try SafeFiles.strictChildren(partitions).contains(where: { $0.lastPathComponent.hasPrefix("launch-preview-") }) {
            throw SwitchError.blocked(L10n.tr("Turn off persistent browser storage in Claude before transferring these conversations."))
        }
        let projects = try SafeFiles.strictChildren(environment.projects)
        for session in sessions {
            guard let cli = session.cliSessionID, UUID(uuidString: cli) != nil else { throw SwitchError.unsafePath }
            let matches = try projects.filter { project in
                guard try project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { return false }
                let file = project.appendingPathComponent(cli + ".jsonl")
                try SafeFiles.validateAncestors(file)
                return FileManager.default.fileExists(atPath: file.path)
            }
            guard matches.count == 1, let project = matches.first else {
                throw SwitchError.blocked(L10n.tr("This conversation's local history is missing or ambiguous. Nothing was transferred."))
            }
            let transcript = project.appendingPathComponent(cli + ".jsonl")
            let history = try SafeFiles.read(transcript, limit: maximumBytes)
            result[transcript.path] = .sha256(digest(history))
            let companions = try SafeFiles.strictChildren(project).filter { ownedComponent($0.lastPathComponent, ids: [cli]) }
            for file in companions { result[file.path] = try fingerprint(file) }
            try verifySubagents(history, project: project, cli: cli, snapshots: &result)
            let record = try SafeFiles.json(SafeFiles.child(session.recordRelativePath, of: environment.desktop), limit: 2 * 1024 * 1024)
            var directories = [record["cwd"].string, record["worktreePath"].string].compactMap { $0 }
            var granted = Set<String>()
            for update in record["sessionPermissionUpdates"].array ?? [] {
                let paths = (update["directories"].array ?? []).compactMap(\.string)
                if update["type"].string == "addDirectories" { granted.formUnion(paths) }
                if update["type"].string == "removeDirectories" { granted.subtract(paths) }
            }
            directories += granted
            for path in Set(directories) {
                guard path.hasPrefix("/"), !path.contains("\0") else { throw SwitchError.unsafePath }
                let url = URL(fileURLWithPath: path); try SafeFiles.validateAncestors(url)
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else {
                    throw SwitchError.blocked(L10n.tr("A conversation folder is unavailable. Restore access before switching accounts."))
                }
            }
        }
        return result
    }

    private static func validateQueue(_ data: Data, at file: URL, sessionID: String) throws {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["sessionId"] as? String == sessionID, let entries = value["entries"] as? [[String: Any]],
              entries.count <= 512 else { throw invalidHistory }
        var messages = Set<String>(), blobs = Set<String>()
        for entry in entries {
            guard let id = entry["uuid"] as? String, messages.insert(id).inserted,
                  let message = entry["msg"] as? [String: Any], message["uuid"] as? String == id,
                  message["type"] as? String == "user", let body = message["message"] as? [String: Any],
                  body["role"] as? String == "user", body["content"] != nil else { throw invalidHistory }
        }
        func references(_ object: Any, depth: Int) throws {
            guard depth < 32 else { throw tooLarge }
            if let fields = object as? [String: Any] {
                if let blob = fields["blob"] {
                    guard let hash = blob as? String, hash.count == 64,
                          hash.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) }) else { throw invalidHistory }
                    blobs.insert(hash)
                }
                for value in fields.values { try references(value, depth: depth + 1) }
            } else if let values = object as? [Any] { for value in values { try references(value, depth: depth + 1) } }
        }
        try references(value, depth: 0)
        let folder = file.deletingPathExtension()
        var bytes = 0
        for hash in blobs {
            let data = try SafeFiles.read(SafeFiles.child(hash, of: folder), limit: maximumBytes - bytes)
            guard digest(data) == hash else { throw invalidHistory }
            bytes += data.count
        }
    }

    private static var invalidHistory: SwitchError {
        .malformed(L10n.tr("The conversation history could not be verified. Its original data is unchanged."))
    }

    private static func verifySubagents(_ history: Data, project: URL, cli: String,
                                       snapshots: inout [String: FileExpectation]) throws {
        var pending = [history], seen = Set<String>()
        while let data = pending.popLast() {
            for line in data.split(separator: 10) where !line.isEmpty {
                guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    throw SwitchError.malformed(L10n.tr("The conversation history could not be verified. Its original data is unchanged."))
                }
                guard let result = row["toolUseResult"] as? [String: Any], let agent = result["agentId"] as? String else { continue }
                guard !agent.isEmpty, agent.count <= 128, agent.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
                    throw SwitchError.unsafePath
                }
                guard seen.insert(agent).inserted else { continue }
                guard seen.count <= 512 else { throw tooLarge }
                let nested = project.appendingPathComponent(cli + "/subagents/agent-" + agent + ".jsonl")
                let flat = project.appendingPathComponent("agent-" + agent + ".jsonl")
                try SafeFiles.validateAncestors(nested); try SafeFiles.validateAncestors(flat)
                let file = FileManager.default.fileExists(atPath: nested.path) ? nested : flat
                let contents = try SafeFiles.read(file, limit: maximumBytes)
                snapshots[file.path] = .sha256(digest(contents)); pending.append(contents)
                let metadata = file.deletingPathExtension().appendingPathExtension("meta.json")
                if FileManager.default.fileExists(atPath: metadata.path) { snapshots[metadata.path] = try fingerprint(metadata) }
            }
        }
    }

    static func validate(_ snapshots: [String: FileExpectation]) throws {
        for (path, expected) in snapshots where try fingerprint(URL(fileURLWithPath: path)) != expected { throw SwitchError.changed }
    }
    private static var tooLarge: SwitchError {
        .blocked(L10n.tr("The conversation resources exceed the safe transfer limit. Nothing was omitted or transferred."))
    }
}
