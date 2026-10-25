import Foundation
import SwitchCore
import SwitchStorage

struct MigrationChange {
    var relative: String
    var data: Data?
    var expectation: FileExpectation
    var files: [ArchiveFile]?
    var directories: [String] = []
    var sourceRelative: String?
    var sourceExpectation: FileExpectation?
    var removesSource: Bool { data == nil && files == nil }
}
enum MigrationBuilder {
    static func resolve(sessions: [Conversation], environment: MacEnvironment) throws -> [Conversation] {
        var records: [Conversation] = []
        for members in Dictionary(grouping: sessions, by: { $0.accountID + "/" + $0.organizationID }).values {
            guard let first = members.first else { continue }
            records += try ConversationRecords.readScope(desktop: environment.desktop,
                                                         accountID: first.accountID, organizationID: first.organizationID)
        }
        guard !records.contains(where: { $0.invalidLineage == true }) else { throw ConversationTree.unresolved }
        let tree = ConversationTree(records)
        return try tree.expanded(sessions).sorted { $0.id < $1.id }
    }
    static func destinationRelative(session: Conversation, target: Account) throws -> String {
        guard let org = target.organizationID, UUID(uuidString: org) != nil, UUID(uuidString: target.id) != nil,
              LocalID.isSession(session.sessionID) else { throw SwitchError.unsafePath }
        return "claude-code-sessions/\(target.id)/\(org)/\(session.sessionID).json"
    }
    static func expectation(at url: URL) throws -> FileExpectation {
        try ConversationResources.fingerprint(url)
    }
    static func changes(sessions: [Conversation], target: Account, environment: MacEnvironment,
                        expectedDigests: [String: String], destinations: [String: FileExpectation],
                        resources: [String: FileExpectation] = [:], preparedTransfers: [String: Data] = [:]) throws -> [MigrationChange] {
        var updates: [MigrationChange] = [], removals: [MigrationChange] = []
        let resolved = try resolve(sessions: sessions, environment: environment)
        guard Set(resolved.map(\.id)) == Set(sessions.map(\.id)) else { throw SwitchError.changed }
        if let org = target.organizationID, !sessions.isEmpty {
            let existing = try ConversationRecords.readScope(desktop: environment.desktop, accountID: target.id, organizationID: org)
            let sourceIDs = Set(sessions.map(\.sessionID))
            let existingTree = ConversationTree(existing)
            for record in existing where sourceIDs.contains(record.sessionID) {
                guard existingTree.isValid(record), existingTree.members(of: record).allSatisfy({ sourceIDs.contains($0.sessionID) }) else {
                    throw ConversationTree.unresolved
                }
            }
        }
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
            let transferred = try SessionTransferRecord.data(from: record)
            // Normal shutdown can flush new task metadata. Keep the complete final record while
            // pinning its identity, ancestry and workspace to the exact pre-quit snapshot.
            let finalized = try preparedTransfers[relative].map { try SessionTransferRecord.sameIdentity($0, as: record) } ?? false
            guard expectedDigests[session.id] == digest(data) || finalized else {
                throw SwitchError.changed
            }
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
            updates.append(MigrationChange(relative: relative, data: transferred, expectation: expected))
            removals.append(MigrationChange(relative: session.recordRelativePath, data: nil, expectation: .sha256(digest(data))))
        }
        let finalizing = !preparedTransfers.isEmpty
        let companions = try ConversationResources.companions(sessions: sessions, target: target, environment: environment,
                                                               trustedTargets: finalizing ? resources : [:])
        let currentResources = companionExpectations(companions)
        if finalizing {
            // Account-scoped resources may be flushed at quit. Their complete final payloads are
            // retained; existing targets remain pinned, and a newly discovered target must be absent.
            for (path, expected) in currentResources where path.hasPrefix("target:") {
                guard expected == (resources[path] ?? .absent) else { throw SwitchError.changed }
            }
            for (path, expected) in resources where path.hasPrefix("target:") && currentResources[path] == nil {
                guard expected == .absent else { throw SwitchError.changed }
            }
        } else if currentResources != resources.filter({ !$0.key.hasPrefix("presentation:") }) { throw SwitchError.changed }
        updates += companions.filter { !$0.removesSource }
        removals = companions.filter(\.removesSource) + removals
        // Every destination must be installed before any source index is removed. Transcripts remain shared.
        return updates + removals
    }

    static func companionExpectations(_ changes: [MigrationChange]) -> [String: FileExpectation] {
        var result: [String: FileExpectation] = [:]
        for change in changes where !change.removesSource {
            result["target:" + change.relative] = change.expectation
            if let source = change.sourceRelative, let expected = change.sourceExpectation { result["source:" + source] = expected }
        }
        return result
    }

    static func stage(_ changes: [MigrationChange], in transaction: FileTransaction) throws {
        for change in changes {
            if let files = change.files {
                try transaction.stageContainer(change.relative, files: files, directories: change.directories, expectation: change.expectation,
                                               sourceRelative: change.sourceRelative, sourceExpectation: change.sourceExpectation)
            } else {
                try transaction.stage(relative: change.relative, data: change.data, expectation: change.expectation,
                                      removalAfterInstall: change.removesSource,
                                      sourceRelative: change.sourceRelative, sourceExpectation: change.sourceExpectation)
            }
        }
    }

    static func verifyDestination(sessions: [Conversation], target: Account, environment: MacEnvironment) throws {
        guard !sessions.isEmpty else { return }
        guard let org = target.organizationID else { throw SwitchError.unsafePath }
        let records = try ConversationRecords.readScope(desktop: environment.desktop, accountID: target.id, organizationID: org)
        let tree = ConversationTree(records), ids = Set(sessions.map(\.sessionID))
        let selected = records.filter { ids.contains($0.sessionID) }
        guard Set(selected.map(\.sessionID)) == ids, Set(try tree.expanded(selected).map(\.sessionID)) == ids else {
            throw ConversationTree.unresolved
        }
        for record in selected {
            guard sessions.contains(where: { $0.sessionID == record.sessionID && $0.cliSessionID == record.cliSessionID &&
                $0.parentSessionID == record.parentSessionID }) else { throw SwitchError.changed }
        }
    }
}
