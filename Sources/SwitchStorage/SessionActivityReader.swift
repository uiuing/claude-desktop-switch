import Foundation
import SwitchCore

/// Reads metadata of task records only. Titles, focus times, output artifacts and message bodies are ignored.
public actor SessionActivityReader {
    public struct Observation: Sendable {
        public var changed: Bool
        public var complete: Bool
        public var observedAt: Date
    }
    private let desktop: URL
    private let projects: URL
    private var scope: String?
    private var previous: [String: FileStamp] = [:]
    private var last: Observation?
    public init(desktop: URL, projects: URL) { self.desktop = desktop; self.projects = projects }

    public func scan(accountID: String, organizationID: String, accounts: [Account], conversations: [Conversation],
                     now: Date = Date()) -> Observation {
        guard UUID(uuidString: accountID) != nil, UUID(uuidString: organizationID) != nil else {
            return Observation(changed: false, complete: false, observedAt: now)
        }
        let key = accountID + ":" + organizationID
        if scope != key { scope = key; previous = [:]; last = nil }
        if let last, now.timeIntervalSince(last.observedAt) >= 0, now.timeIntervalSince(last.observedAt) < 60 { return last }
        var stamps: [String: FileStamp] = [:], complete = true, budget = 10_000
        func children(_ directory: URL) -> [URL] {
            guard budget > 0 else { complete = false; return [] }
            do {
                let entries = try SafeFiles.children(directory)
                if entries.count > budget { complete = false }
                let kept = Array(entries.prefix(budget)); budget -= kept.count
                return kept
            } catch { complete = false; return [] }
        }
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        func directory(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        func stamp(_ file: URL) {
            guard budget > 0 else { complete = false; return }
            budget -= 1
            do {
                let fd = try SafeFiles.openRead(file)
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                let value = try SafeFiles.stamp(fd)
                guard value.modified <= now.addingTimeInterval(60) else { complete = false; return }
                stamps[file.path] = value
            } catch { complete = false }
        }
        func transcript(_ file: URL) {
            stamp(file)
            let agents = file.deletingPathExtension().appendingPathComponent("subagents")
            if exists(agents) {
                for child in children(agents) where child.pathExtension == "jsonl" { stamp(child) }
            }
        }
        let owned = conversations.filter { $0.accountID == accountID && $0.organizationID == organizationID && !$0.archived && $0.kind == .code }
        var transcriptOwners: [String: Set<String>] = [:]
        for session in conversations {
            if let cli = session.cliSessionID { transcriptOwners[cli, default: []].insert(session.accountID + ":" + session.organizationID) }
        }
        var wanted = Set<String>()
        for session in owned {
            guard let cli = session.cliSessionID, UUID(uuidString: cli) != nil else { complete = false; continue }
            guard transcriptOwners[cli] == [key] else { complete = false; continue }
            wanted.insert(cli)
        }
        if !wanted.isEmpty {
            var found = Set<String>()
            for project in children(projects) where directory(project) {
                for file in children(project) where file.pathExtension == "jsonl" && wanted.contains(file.deletingPathExtension().lastPathComponent) {
                    found.insert(file.deletingPathExtension().lastPathComponent); transcript(file)
                }
            }
            if found != wanted { complete = false }
        }

        // Cowork owns its records under the account and organization, including agent/ and dispatch children.
        var roots = [desktop.appendingPathComponent("local-agent-mode-sessions/" + key.replacingOccurrences(of: ":", with: "/"))]
        let shortAccount = String(accountID.prefix(8)), shortOrg = String(organizationID.prefix(8))
        if Set(accounts.filter { $0.id.hasPrefix(shortAccount) }.map(\.id)).count == 1,
           Set(accounts.compactMap(\.organizationID).filter { $0.hasPrefix(shortOrg) }).count == 1 {
            roots.append(desktop.appendingPathComponent("local-agent-mode-sessions/" + shortAccount + "/" + shortOrg))
        } else if exists(desktop.appendingPathComponent("local-agent-mode-sessions/" + shortAccount + "/" + shortOrg)) {
            complete = false
        }
        func sessionFolder(_ folder: URL) {
            let audit = folder.appendingPathComponent("audit.jsonl")
            if exists(audit) { stamp(audit) }
            let nested = folder.appendingPathComponent(".claude/projects")
            if exists(nested) {
                for project in children(nested) where directory(project) {
                    for file in children(project) where file.pathExtension == "jsonl" { transcript(file) }
                }
            }
            if !exists(audit) && !exists(nested) { complete = false }
        }
        if conversations.contains(where: { $0.accountID == accountID && $0.organizationID == organizationID && $0.kind == .cowork && !$0.archived }),
           !roots.contains(where: { exists($0) }) { complete = false }
        for root in roots where exists(root) {
            var containers = [root]
            let agent = root.appendingPathComponent("agent")
            if exists(agent) { containers.append(agent) }
            for container in containers {
                for folder in children(container) where directory(folder) {
                    let name = folder.lastPathComponent
                    guard LocalID.isSession(name) || name.range(of: "^[0-9a-fA-F]{8}$", options: .regularExpression) != nil else { continue }
                    sessionFolder(folder)
                }
            }
        }
        let changed = stamps.contains { path, current in
            guard current.size > 0 else { return false }
            if let old = previous[path] { return current != old }
            return current.modified >= now.addingTimeInterval(-60)
        }
        previous = stamps
        let observation = Observation(changed: changed, complete: complete, observedAt: now)
        last = observation
        return observation
    }
}
