import Foundation
import SwitchCore

public enum ConversationRecords {
    public static func readScope(desktop: URL, accountID: String, organizationID: String) throws -> [Conversation] {
        guard UUID(uuidString: accountID) != nil, UUID(uuidString: organizationID) != nil else { throw SwitchError.unsafePath }
        let relative = "claude-code-sessions/\(accountID)/\(organizationID)"
        let folder = try SafeFiles.child(relative, of: desktop)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let files = try SafeFiles.strictChildren(folder)
        guard files.count <= 10_000 else { throw ConversationTree.unresolved }
        var result: [Conversation] = [], bytes = 0
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let id = file.deletingPathExtension().lastPathComponent
            guard file.pathExtension == "json", LocalID.isSession(id) else { continue }
            let data = try SafeFiles.read(file, limit: 2 * 1024 * 1024)
            bytes += data.count
            guard bytes <= 64 * 1024 * 1024 else { throw ConversationTree.unresolved }
            let record = try JSONDecoder().decode(JSONValue.self, from: data)
            guard record["sessionId"].string == id else { throw ConversationTree.unresolved }
            let lineage = ConversationLineage.read(record, sessionID: id)
            result.append(Conversation(id: accountID + "/" + organizationID + "/code/" + id, sessionID: id,
                accountID: accountID, organizationID: organizationID,
                title: record["title"].string ?? L10n.tr("Untitled conversation"), kind: .code,
                modifiedAt: Dates.parse(record["lastActivityAt"]) ?? Dates.parse(record["updatedAt"]) ?? .distantPast,
                model: record["model"].string, project: record["cwd"].string,
                recordRelativePath: relative + "/" + file.lastPathComponent,
                cliSessionID: record["cliSessionId"].string, archived: record["isArchived"].bool ?? false,
                parentSessionID: lineage.parent, invalidLineage: lineage.invalid ? true : nil))
        }
        return result
    }
}
