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
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            print("{\"mode\":\"read-only\",\"status\":\"unavailable\",\"writesToClaude\":false}")
        }
    }
}
