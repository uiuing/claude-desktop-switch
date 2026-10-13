import Foundation
import SwitchCore
import SwitchStorage

struct MigrationChange {
    var relative: String
    var data: Data?
    var expectation: FileExpectation
}
enum MigrationBuilder {
    static func destinationRelative(session: Conversation, target: Account) throws -> String {
        guard let org = target.organizationID, UUID(uuidString: org) != nil, UUID(uuidString: target.id) != nil,
              LocalID.isSession(session.sessionID) else { throw SwitchError.unsafePath }
        return "claude-code-sessions/\(target.id)/\(org)/\(session.sessionID).json"
    }
    static func expectation(at url: URL) throws -> FileExpectation {
        try SafeFiles.validateAncestors(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        return .sha256(digest(try SafeFiles.read(url, limit: 2 * 1024 * 1024)))
    }
    static func changes(sessions: [Conversation], target: Account, environment: MacEnvironment,
                        expectedDigests: [String: String], destinations: [String: FileExpectation],
                        modes: [String: SessionTransferMode]) throws -> [MigrationChange] {
        var updates: [MigrationChange] = [], removals: [MigrationChange] = []
        var seen = Set<String>()
        let accountRoot = environment.desktop.appendingPathComponent("claude-code-sessions").appendingPathComponent(target.id)
        // Claude Desktop leaves session-less org folders (e.g. only scheduled-tasks.json) behind after account switches.
        let organizations = ((try? SafeFiles.children(accountRoot)) ?? []).filter { org in
            UUID(uuidString: org.lastPathComponent) != nil && ((try? SafeFiles.children(org)) ?? []).contains {
                $0.pathExtension == "json" && LocalID.isSession($0.deletingPathExtension().lastPathComponent)
            }
        }
        if !sessions.isEmpty, organizations.count > 1 {
            throw SwitchError.blocked(L10n.tr("The target account has multiple local organizations. A migration destination cannot be selected safely."))
        }
        for session in sessions {
            if let reason = SessionLibrary.migrationBlocker(session, target: target) { throw SwitchError.blocked(reason) }
            guard UUID(uuidString: session.accountID) != nil, UUID(uuidString: session.organizationID) != nil,
                  let cli = session.cliSessionID, UUID(uuidString: cli) != nil else { throw SwitchError.unsafePath }
            let expectedSource = "claude-code-sessions/\(session.accountID)/\(session.organizationID)/\(session.sessionID).json"
            guard session.recordRelativePath.lowercased() == expectedSource.lowercased() else { throw SwitchError.unsafePath }
            let source = try SafeFiles.child(session.recordRelativePath, of: environment.desktop)
            let data = try SafeFiles.read(source, limit: 2 * 1024 * 1024)
            guard expectedDigests[session.id] == digest(data) else { throw SwitchError.changed }
            let record = try JSONDecoder().decode(JSONValue.self, from: data)
            guard record["sessionId"].string == session.sessionID, record["cliSessionId"].string == cli,
                  let cwd = record["cwd"].string, cwd.hasPrefix("/") else {
                throw SwitchError.malformed(L10n.tr("The conversation record does not match the preview."))
            }
            var transcriptFound = false
            for project in (try? SafeFiles.children(environment.projects)) ?? [] {
                let path = project.appendingPathComponent(cli + ".jsonl")
                if FileManager.default.fileExists(atPath: path.path), let fd = try? SafeFiles.openRead(path) {
                    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); try handle.close()
                    transcriptFound = true; break
                }
            }
            guard transcriptFound else { throw SwitchError.missing(L10n.tr("The local transcript no longer exists. No unusable resume index will be created.")) }
            let relative = try destinationRelative(session: session, target: target)
            guard seen.insert(relative).inserted else { throw SwitchError.malformed(L10n.tr("Duplicate transaction target.")) }
            let destination = try SafeFiles.child(relative, of: environment.desktop)
            guard let expected = destinations[relative], try expectation(at: destination) == expected else { throw SwitchError.changed }
            if expected != .absent {
                let existing = try SafeFiles.json(destination, limit: 2 * 1024 * 1024)
                guard existing["sessionId"].string == session.sessionID, existing["cliSessionId"].string == cli else {
                    throw SwitchError.blocked(L10n.tr("The target record points to a different conversation and cannot be replaced."))
                }
            }
            // Resume metadata is replaced, while permission grants, secrets and remote controls are never transferred.
            let allowed: Set<String> = ["sessionId", "cliSessionId", "cwd", "originCwd", "createdAt", "lastActivityAt",
                                       "lastFocusedAt", "title", "titleSource", "model", "effort", "isArchived"]
            var clean = (record.object ?? [:]).filter { allowed.contains($0.key) }
            clean["permissionMode"] = .string("default")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            updates.append(MigrationChange(relative: relative, data: try encoder.encode(JSONValue.object(clean)), expectation: expected))
            if (modes[session.id] ?? .move) == .move {
                removals.append(MigrationChange(relative: session.recordRelativePath, data: nil, expectation: .sha256(digest(data))))
            }
        }
        // Every destination must be installed before any source index is removed. Transcripts remain shared.
        return updates + removals
    }
}
