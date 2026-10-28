import Foundation
import SwitchCore
import SwitchStorage
import SwitchMac

@main
struct Inspect {
    static func main() async {
        let environment = MacEnvironment()
        do {
            let reader = LocalReader(desktop: environment.desktop, codeConfig: environment.codeConfig)
            let inventory = try await reader.scan()
            var result: [String: Any] = [
                "mode": "read-only", "claudeVersion": environment.version ?? "unavailable",
                "activeIdentityFound": inventory.activeAccountID != nil,
                "localAccounts": inventory.accounts.count,
                "accountsWithLocalUsage": inventory.cachedUsage.count,
                "quotaSlots": inventory.accounts.count * 2,
                "codeRecords": inventory.conversations.filter { $0.kind == .code }.count,
                "coworkRecords": inventory.conversations.filter { $0.kind == .cowork }.count,
                "attributedUsageAvailable": inventory.usage != nil,
                "usageWindowCount": inventory.usage?.windows.count ?? 0,
                "warnings": inventory.warnings,
                "writesToClaude": false, "keychainAccess": false, "networkRequests": 0,
            ]
            if CommandLine.arguments.contains("--tokens") {
                let scanner = TokenScanner(projects: environment.projects, keepsRequestLedger: true)
                let report = try await scanner.scan(since: Date().addingTimeInterval(-30 * 86400))
                result["tokenScan"] = ["files": report.scannedFiles, "models": report.models.count,
                    "deduplicatedRequests": report.events.count, "incompleteRequests": report.incompleteRequests,
                    "unattributedRequests": report.unattributedRequests, "partial": report.partial,
                    "skippedFiles": report.skippedFiles]
            }
            if CommandLine.arguments.contains("--presentation-check") {
                let library = try await LibraryStore(root: environment.root).load()
                result["presentationCheck"] = presentationCheck(environment, sessions: inventory.conversations, follows: library.follows)
                result["recentOperations"] = SwitchDiagnostics.recentOperations(environment: environment)
            }
            if CommandLine.arguments.contains("--history-check") {
                let title = readLine() ?? ""
                let selected = inventory.conversations.filter {
                    $0.kind == .code && $0.accountID == inventory.activeAccountID && $0.title == title
                }
                var check = ["matchedConversations": selected.count]
                if selected.count == 1 {
                    let sessions = try ConversationTree(inventory.conversations).expanded(selected)
                    check.merge(SwitchDiagnostics.inspectHistory(sessions: sessions, environment: environment)) { _, new in new }
                }
                result["historyCheck"] = check
            }
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            print("{\"mode\":\"read-only\",\"status\":\"unavailable\",\"writesToClaude\":false}")
        }
    }

    /// Inspect bytes in memory only. Never emit storage keys, values, paths or error descriptions.
    private static func presentationCheck(_ environment: MacEnvironment, sessions: [Conversation], follows: [FollowRule]) -> [String: Any] {
        let root = environment.desktop.appendingPathComponent("Local Storage/leveldb")
        func stamp(_ file: URL) throws -> FileStamp {
            let handle = FileHandle(fileDescriptor: try SafeFiles.openRead(file), closeOnDealloc: true)
            defer { try? handle.close() }
            return try SafeFiles.stamp(handle.fileDescriptor)
        }
        do {
            let entries = try SafeFiles.strictChildren(root)
            guard entries.count <= 20_000 else { return ["status": "unavailable"] }
            var files: [String: Data] = [:], stamps: [URL: FileStamp] = [:], total: Int64 = 0
            for file in entries {
                let before = try stamp(file)
                total += before.size
                guard before.size >= 0, total <= 128 * 1024 * 1024 else { return ["status": "unavailable"] }
                files[file.lastPathComponent] = try SafeFiles.read(file, limit: 128 * 1024 * 1024)
                stamps[file] = before
            }
            guard Set(try SafeFiles.strictChildren(root)) == Set(entries) else { return ["status": "changed"] }
            for (file, before) in stamps where try stamp(file) != before { return ["status": "changed"] }
            do {
                let values = try LevelDBSnapshot.read(files)
                try SwitchDiagnostics.verifyPresentation(files: files, sessions: sessions)
                let saved = SwitchDiagnostics.inspectSavedPresentation(files: files, sessions: sessions, environment: environment, follows: follows)
                let blocked = saved["invalid", default: 0] + saved["mergeConflicts", default: 0] > 0
                return ["status": blocked ? "blocked" : "verified", "localStorageStatus": "verified",
                        "files": files.count, "entries": values.count, "savedPresentations": saved]
            } catch { return ["status": "invalid", "files": files.count] }
        } catch SwitchError.changed { return ["status": "changed"] }
        catch { return ["status": "unavailable"] }
    }
}
