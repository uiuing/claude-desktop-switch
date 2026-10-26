import Foundation
import SwitchCore
import SwitchStorage

/// Read-only checks for switch-inspect. Results contain no storage keys, values or identities.
public enum SwitchDiagnostics {
    public static func verifyPresentation(files: [String: Data], sessions: [Conversation]) throws {
        let source = files.map { ArchiveFile(path: ConversationPresentation.prefix + $0.key, data: $0.value, sha256: digest($0.value)) }
        let empty = try LevelDBSnapshot.files([:]).map {
            ArchiveFile(path: ConversationPresentation.prefix + $0.key, data: $0.value, sha256: digest($0.value))
        }
        let target = LoginSnapshot(accountID: "", version: "", createdAt: .distantPast, auth: [:], files: empty,
                                   directories: ["Local Storage", "Local Storage/leveldb"])
        let ids = Set(sessions.filter { $0.kind == .code }.flatMap { [$0.sessionID] + ($0.cliSessionID.map { [$0] } ?? []) })
        _ = try ConversationPresentation.merge(source: source, target: target, ids: ids)
    }

    public static func inspectSavedPresentation(files: [String: Data], sessions: [Conversation],
                                                environment: MacEnvironment, follows: [FollowRule] = []) -> [String: Int] {
        let source = files.map { ArchiveFile(path: ConversationPresentation.prefix + $0.key, data: $0.value, sha256: digest($0.value)) }
        let current = LoginSnapshot(accountID: "", version: "", createdAt: .distantPast, auth: [:], files: source,
                                    directories: ["Local Storage", "Local Storage/leveldb"])
        var counts = ["checked": 0, "invalid": 0, "mergeConflicts": 0]
        var invalidOwners = Set<String>()
        var invalidIDs = Set<String>()
        for session in sessions where session.kind == .code {
            do {
                let account = Account(id: session.accountID, organizationID: session.organizationID)
                let relative = try ConversationPresentation.relative(session, target: account)
                let file = try SafeFiles.child(relative, of: environment.desktop)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                counts["checked", default: 0] += 1
                let data = try SafeFiles.read(file, limit: 64 * 1024 * 1024)
                let metadata = try JSONDecoder().decode(ConversationPresentation.Saved.self, from: data)
                if metadata.cliSessionID != session.cliSessionID {
                    counts["historyIDMismatches", default: 0] += 1
                    if metadata.cliSessionID.lowercased() == session.cliSessionID?.lowercased() { counts["caseOnlyMismatches", default: 0] += 1 }
                    if try ConversationPresentation.canRebind(metadata, session: session) {
                        counts["staleBindingsWithCompleteStableSessionScope", default: 0] += 1
                    }
                }
                let saved = try ConversationPresentation.saved(data, session: session)
                do {
                    _ = try ConversationPresentation.merge(source: saved, target: current,
                        ids: Set([session.sessionID] + (session.cliSessionID.map { [$0] } ?? [])))
                } catch { counts["mergeConflicts", default: 0] += 1 }
            } catch {
                counts["invalid", default: 0] += 1
                invalidOwners.insert(session.accountID)
                invalidIDs.insert(session.id)
            }
        }
        counts["recentEmptyRollbacksForInvalidTarget"] = recentJournals(environment).filter {
            $0.phase == "recovered" && $0.entries.isEmpty && invalidOwners.contains($0.targetAccountID)
        }.count
        let failed = recentJournals(environment).filter { $0.phase == "recovered" && $0.entries.isEmpty }
        counts["recentEmptyRollbacksForInvalidSource"] = failed.filter { $0.sourceAccountID.map(invalidOwners.contains) == true }.count
        let tree = ConversationTree(sessions)
        counts["recentEmptyRollbacksWithInvalidFollow"] = failed.filter { journal in
            let selected = SessionLibrary.followedSessions(sessions, rules: follows,
                activeAccountID: journal.sourceAccountID, targetAccountID: journal.targetAccountID)
            return ((try? tree.expanded(selected)) ?? []).contains { invalidIDs.contains($0.id) }
        }.count
        return counts
    }

    public static func recentOperations(environment: MacEnvironment) -> [[String: Any]] {
        recentJournals(environment).map { journal in
            ["createdAt": ISO8601DateFormatter().string(from: journal.createdAt),
             "phase": ["preparing", "applying", "committed", "recovering", "recovered"].contains(journal.phase) ? journal.phase : "unknown",
             "entries": journal.entries.count, "startedEntries": journal.entries.filter(\.started).count]
        }
    }

    private static func recentJournals(_ environment: MacEnvironment) -> [TransactionJournal] {
        let root = environment.root.appendingPathComponent("transactions")
        guard let children = try? SafeFiles.children(root) else { return [] }
        let journals = children.compactMap { child -> TransactionJournal? in
            guard UUID(uuidString: child.lastPathComponent) != nil else { return nil }
            return try? FileTransaction(existing: child, live: environment.desktop).journal
        }.sorted { $0.createdAt > $1.createdAt }.prefix(6)
        return Array(journals)
    }
}
