import Foundation
import CryptoKit
import SwitchCore
import SwitchStorage

/// Shared histories are checked in place. Their size must not be limited by the attachment-copy budget.
enum ConversationHistory {
    static func scan(_ file: URL) throws -> (digest: String, agents: Set<String>) {
        var pending = Data(), agents = Set<String>()
        func line(_ data: Data) throws {
            guard !data.isEmpty else { return }
            guard let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw invalid }
            if let result = row["toolUseResult"] as? [String: Any], let agent = result["agentId"] as? String {
                guard !agent.isEmpty, agent.count <= 128,
                      agent.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { throw SwitchError.unsafePath }
                agents.insert(agent)
                guard agents.count <= 512 else { throw invalid }
            }
        }
        let hash = try hash(file) { chunk in
            let parts = chunk.split(separator: 10, omittingEmptySubsequences: false)
            for (index, part) in parts.enumerated() {
                pending.append(contentsOf: part)
                guard pending.count <= 64 * 1024 * 1024 else { throw invalid }
                if index < parts.count - 1 { try line(pending); pending.removeAll(keepingCapacity: true) }
            }
        }
        try line(pending)
        return (hash, agents)
    }

    static func priorSessionIDs(_ record: JSONValue) throws -> [String] {
        let value = record["priorCliSessionIds"]
        if value == .null { return [] }
        guard let entries = value.array else { throw invalid }
        return try Array(Set(entries.map {
            guard let id = $0.string, UUID(uuidString: id) != nil else { throw invalid }
            return id.lowercased()
        })).sorted()
    }

    /// Rewinds can retain agent transcripts under a recorded previous CLI session.
    /// Resolve only that conversation's declared history, never unrelated project sessions.
    static func dependencies(_ history: URL, project: URL, cli: String, priorSessionIDs: [String]) throws
        -> (files: [String: FileExpectation], agentHistories: Int, historicalAgentHistories: Int) {
        let owners = Set([cli] + priorSessionIDs)
        var pending = [(history, cli)], seen = Set<URL>(), files: [String: FileExpectation] = [:], historical = 0
        while let (file, owner) = pending.popLast() {
            guard seen.insert(file).inserted else { continue }
            guard seen.count <= 513 else { throw invalid }
            let scan = try scan(file)
            files[file.path] = .sha256(scan.digest)
            if file != history {
                if owner != cli { historical += 1 }
                let metadata = file.deletingPathExtension().appendingPathExtension("meta.json")
                if FileManager.default.fileExists(atPath: metadata.path) { files[metadata.path] = try fingerprint(metadata) }
            }
            for agent in scan.agents {
                let name = "agent-" + agent + ".jsonl"
                let nested = try SafeFiles.child(owner + "/subagents/" + name, of: project)
                let flat = try SafeFiles.child(name, of: project)
                if FileManager.default.fileExists(atPath: nested.path) { pending.append((nested, owner)) }
                else if FileManager.default.fileExists(atPath: flat.path) { pending.append((flat, owner)) }
                else {
                    let alternatives = try owners.subtracting([owner]).sorted().compactMap { id -> (URL, String)? in
                        let candidate = try SafeFiles.child(id + "/subagents/" + name, of: project)
                        return FileManager.default.fileExists(atPath: candidate.path) ? (candidate, id) : nil
                    }
                    guard alternatives.count == 1, let candidate = alternatives.first else {
                        RuntimeLog.validation(.conversationHistory, check: .filePath)
                        throw SwitchError.blocked(L10n.tr("This conversation's subagent history is missing or ambiguous. Nothing was transferred."))
                    }
                    pending.append(candidate)
                }
            }
        }
        return (files, seen.count - 1, historical)
    }

    static func fingerprint(_ url: URL) throws -> FileExpectation {
        try SafeFiles.validateAncestors(url)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { return .absent }
        if !directory.boolValue { return .sha256(try hash(url)) }
        var folders: [String] = [], files: [(String, String)] = []
        func visit(_ folder: URL, _ path: String, _ depth: Int) throws {
            guard depth < 32, folders.count + files.count < ConversationResources.maximumFiles else { throw invalid }
            folders.append(path)
            for entry in try SafeFiles.strictChildren(folder) {
                let relative = path + "/" + entry.lastPathComponent
                if try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { try visit(entry, relative, depth + 1) }
                else {
                    guard folders.count + files.count < ConversationResources.maximumFiles else { throw invalid }
                    files.append((relative, try hash(entry)))
                }
            }
        }
        try visit(url, "resource", 0)
        var result = SHA256()
        for path in folders.sorted() { result.update(data: Data(("d\0" + path + "\0").utf8)) }
        for (path, sha) in files.sorted(by: { $0.0 < $1.0 }) { result.update(data: Data(("f\0" + path + "\0" + sha + "\0").utf8)) }
        return .directory(hex(result.finalize()))
    }

    private static func hash(_ url: URL, consume: ((Data) throws -> Void)? = nil) throws -> String {
        let fd = try SafeFiles.openRead(url), handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let before = try SafeFiles.stamp(fd)
        var result = SHA256(), count: Int64 = 0
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            count += Int64(chunk.count)
            guard count <= before.size else { throw SwitchError.changed }
            result.update(data: chunk)
            try consume?(chunk)
        }
        guard count == before.size, try SafeFiles.stamp(fd) == before else { throw SwitchError.changed }
        return hex(result.finalize())
    }
    private static func hex(_ hash: SHA256.Digest) -> String { hash.map { String(format: "%02x", $0) }.joined() }
    private static var invalid: SwitchError {
        .malformed(L10n.tr("The conversation history could not be verified. Its original data is unchanged."))
    }
}
