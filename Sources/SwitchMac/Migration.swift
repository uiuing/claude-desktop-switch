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
        // Desktop lists an account's sessions from the organization it is signed in to; a guessed one that differs
        // from where the account's sessions already are would hide what is written.
        if !sessions.isEmpty, target.organizationVerifiedAt == nil, let organization = target.organizationID,
           let existing = organizations.first, existing.lastPathComponent.lowercased() != organization.lowercased() {
            throw SwitchError.blocked(L10n.tr("The organization of the target account is uncertain. Switch to it once and refresh its quota, then try again."))
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
            guard let record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  record["sessionId"] as? String == session.sessionID, record["cliSessionId"] as? String == cli,
                  let cwd = record["cwd"] as? String, cwd.hasPrefix("/") else {
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
            guard transcriptFound else { throw SwitchError.missing(L10n.tr("This conversation's local history is missing, so it cannot be transferred.")) }
            let relative = try destinationRelative(session: session, target: target)
            guard seen.insert(relative).inserted else { throw SwitchError.malformed(L10n.tr("Duplicate transaction target.")) }
            let destination = try SafeFiles.child(relative, of: environment.desktop)
            guard let expected = destinations[relative], try expectation(at: destination) == expected else { throw SwitchError.changed }
            if expected != .absent {
                let targetData = try SafeFiles.read(destination, limit: 2 * 1024 * 1024)
                guard expected == .sha256(digest(targetData)) else { throw SwitchError.changed }
                guard let existing = try JSONSerialization.jsonObject(with: targetData) as? [String: Any],
                      existing["sessionId"] as? String == session.sessionID, existing["cliSessionId"] as? String == cli else {
                    throw SwitchError.blocked(L10n.tr("The target record points to a different conversation and cannot be replaced."))
                }
            }
            updates.append(MigrationChange(relative: relative, data: try SessionTransferRecord.data(from: record), expectation: expected))
            if (modes[session.id] ?? .move) == .move {
                removals.append(MigrationChange(relative: session.recordRelativePath, data: nil, expectation: .sha256(digest(data))))
            }
        }
        // Every destination must be installed before any source index is removed. Transcripts remain shared.
        return updates + removals
    }
}
