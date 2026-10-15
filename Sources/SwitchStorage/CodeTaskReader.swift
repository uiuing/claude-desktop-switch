import Foundation
import SwitchCore

/// Reads only the PID registry and the selected Desktop Code indexes. Never runs the CLI or reads transcripts.
public actor CodeTaskReader {
    private let desktop: URL
    private let registry: URL
    public init(desktop: URL, registry: URL) { self.desktop = desktop; self.registry = registry }

    public func scan(scope: CodeTaskScope, processes: Set<CodeTaskProcess>, followed: [Conversation]) -> CodeTaskSnapshot {
        var complete = processes.count <= 128, tasks: [CodeTask] = [], seen = Set<String>(), budget = 16 * 1024 * 1024
        func read(_ url: URL, limit: Int) throws -> JSONValue {
            try Task.checkCancellation()
            guard budget > 0 else { throw SwitchError.changed }
            let data = try SafeFiles.read(url, limit: min(budget, limit)); budget -= data.count
            return try JSONDecoder().decode(JSONValue.self, from: data)
        }
        func conversation(_ sessionID: String) throws -> Conversation {
            guard LocalID.isSession(sessionID) else { throw SwitchError.unsafePath }
            // A host ID in two organizations cannot establish which organization owns this process.
            let accountRoot = desktop.appendingPathComponent("claude-code-sessions/" + scope.accountID)
            try SafeFiles.validateAncestors(accountRoot)
            let organizations = try FileManager.default.contentsOfDirectory(at: accountRoot, includingPropertiesForKeys: nil)
            guard organizations.count <= 100 else { throw SwitchError.changed }
            for directory in organizations where directory.lastPathComponent != scope.organizationID && UUID(uuidString: directory.lastPathComponent) != nil {
                let candidate = try SafeFiles.child(directory.lastPathComponent + "/" + sessionID + ".json", of: accountRoot)
                guard !FileManager.default.fileExists(atPath: candidate.path) else { throw SwitchError.changed }
            }
            let relative = "claude-code-sessions/" + scope.accountID + "/" + scope.organizationID + "/" + sessionID + ".json"
            let record = try read(SafeFiles.child(relative, of: desktop), limit: 2 * 1024 * 1024)
            guard (record["sessionId"].string ?? record["id"].string) == sessionID,
                  record["isArchived"].bool != true, let cli = record["cliSessionId"].string,
                  UUID(uuidString: cli) != nil else { throw SwitchError.changed }
            let title = record["title"].string ?? record["name"].string ?? L10n.tr("Untitled conversation")
            guard title.utf8.count <= 16_384, (record["cwd"].string?.utf8.count ?? 0) <= 16_384 else { throw SwitchError.changed }
            return Conversation(id: scope.accountID + "/" + scope.organizationID + "/code/" + sessionID,
                sessionID: sessionID, accountID: scope.accountID, organizationID: scope.organizationID,
                title: title, kind: .code, modifiedAt: .distantPast, project: record["cwd"].string,
                recordRelativePath: relative, cliSessionID: cli)
        }
        for process in processes.sorted(by: { $0.pid < $1.pid }).prefix(128) {
            do {
                let value = try read(registry.appendingPathComponent(String(process.pid) + ".json"), limit: 64 * 1024)
                guard value["pid"].number == Double(process.pid), Self.matchesStart(value, process: process) else {
                    complete = false; continue
                }
                guard let entrypoint = value["entrypoint"].string else { complete = false; continue }
                guard ["claude-desktop", "claude-desktop-3p"].contains(entrypoint) else { continue }
                if value["spare"].bool == true { continue }
                guard value["kind"].string == "interactive", let host = value["hostSessionId"].string,
                      LocalID.isSession(host), let cli = value["sessionId"].string, UUID(uuidString: cli) != nil else {
                    complete = false; continue
                }
                let session = try conversation(host)
                guard session.cliSessionID == cli else { complete = false; continue }
                let status = CodeTaskStatus(published: value["status"].string, waitingFor: value["waitingFor"].string)
                if status == .unknown { complete = false }
                tasks.append(.init(conversation: session, status: status, process: process)); seen.insert(session.sessionID)
            } catch { complete = false }
        }
        let duplicates = Dictionary(grouping: tasks, by: { $0.conversation.sessionID }).filter { $0.value.count > 1 }
        if !duplicates.isEmpty {
            complete = false
            var kept = Set<String>()
            tasks = tasks.filter { kept.insert($0.id).inserted }.map { task in
                var task = task
                if duplicates[task.conversation.sessionID] != nil { task.status = .unknown; task.process = nil }
                return task
            }
        }
        let pinned = followed.filter(scope.contains)
        if pinned.count > 100 { complete = false }
        for session in pinned.prefix(100) where !seen.contains(session.sessionID) {
            do {
                let fresh = try conversation(session.sessionID)
                tasks.append(.init(conversation: fresh, status: complete ? .notRunning : .unknown)); seen.insert(session.sessionID)
            } catch { complete = false }
        }
        if !complete {
            for index in tasks.indices where tasks[index].status == .notRunning { tasks[index].status = .unknown }
        }
        return .init(scope: scope, availability: complete ? .ready : .incomplete, tasks: tasks, processes: processes)
    }

    /// The macOS registry uses `LC_ALL=C TZ=UTC ps -o lstart=`. It has whole-second precision;
    /// startedAt must also be after this exact native process birth to reject a reused PID.
    static func matchesStart(_ record: JSONValue, process: CodeTaskProcess) -> Bool {
        guard let token = record["procStart"].string, token.count <= 64,
              let registered = record["startedAt"].number, registered.isFinite,
              registered >= Double(process.started / 1_000) else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let expected = formatter.string(from: Date(timeIntervalSince1970: Double(process.started / 1_000_000)))
        return token.split(whereSeparator: \.isWhitespace) == expected.split(whereSeparator: \.isWhitespace)
    }
}
