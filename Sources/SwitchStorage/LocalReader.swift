import Foundation
import SwitchCore

public actor LocalReader: InventoryReader {
    public let desktop: URL
    public let codeConfig: URL
    public let projects: URL?
    private var recordCache: [String: (FileStamp, Conversation)] = [:]
    private var profileCache: (signature: [String], profile: DesktopProfile.Cache) = ([], DesktopProfile.Cache())
    private var codeAccountCache: (stamp: FileStamp, account: CodeAccount?)?
    /// The Claude Code login in `~/.claude.json`. Only these fields are decoded; the file also holds project history.
    private struct CodeAccount: Decodable { var accountUuid: String?; var emailAddress: String?; var organizationUuid: String? }
    private struct CodeConfig: Decodable { var oauthAccount: CodeAccount? }
    public init(desktop: URL, codeConfig: URL, projects: URL? = nil) {
        self.desktop = desktop; self.codeConfig = codeConfig; self.projects = projects
    }

    public func scan() async throws -> LocalInventory { try await scan(verifiedOrganizations: [:]) }

    /// `verifiedOrganizations`: account → organization the server confirmed for that login's own token.
    public func scan(verifiedOrganizations: [String: String]) async throws -> LocalInventory {
        let config = try SafeFiles.json(desktop.appendingPathComponent("config.json"))
        let active = config["lastKnownAccountUuid"].string.flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }
        var accounts: [String: Account] = [:], conversations: [Conversation] = [], warnings: [String] = []
        if let active { accounts[active] = Account(id: active) }
        var seen = Set<String>()
        var allOrganizations: [String: Set<String>] = [:], sessionOrganizations: [String: Set<String>] = [:]
        for (store, kind) in [("claude-code-sessions", SessionKind.code), ("local-agent-mode-sessions", .cowork)] {
            let base = desktop.appendingPathComponent(store)
            guard FileManager.default.fileExists(atPath: base.path) else { continue }
            for accountDir in try SafeFiles.children(base) {
                guard let uuid = UUID(uuidString: accountDir.lastPathComponent) else { continue }
                let accountID = uuid.uuidString.lowercased()
                if accounts[accountID] == nil { accounts[accountID] = Account(id: accountID) }
                for orgDir in (try? SafeFiles.children(accountDir)) ?? [] {
                    guard UUID(uuidString: orgDir.lastPathComponent) != nil else { continue }
                    let orgID = orgDir.lastPathComponent.lowercased()
                    allOrganizations[accountID, default: []].insert(orgID)
                    let found = conversations.count
                    defer { if conversations.count > found { sessionOrganizations[accountID, default: []].insert(orgID) } }
                    let children = (try? SafeFiles.children(orgDir)) ?? []
                    for entry in children {
                        try Task.checkCancellation()
                        if conversations.count >= 10_000 { warnings.append(L10n.tr("The conversation limit was reached. This list is incomplete.")); break }
                        var file = entry
                        if kind == .cowork && entry.pathExtension != "json" { file = entry.appendingPathComponent("manifest.json") }
                        guard file.pathExtension == "json" else { continue }
                        do {
                            let relative = String(file.path.dropFirst(desktop.path.count + 1))
                            seen.insert(relative)
                            let fd = try SafeFiles.openRead(file)
                            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                            let stamp = try SafeFiles.stamp(fd); try handle.close()
                            if let (old, record) = recordCache[relative], old == stamp { conversations.append(record); continue }
                            let r = try SafeFiles.json(file, limit: 2 * 1024 * 1024)
                            guard let sessionID = r["sessionId"].string ?? r["id"].string,
                                  LocalID.isSession(sessionID) else { continue }
                            let lineage = kind == .code ? ConversationLineage.read(r, sessionID: sessionID) : (parent: nil as String?, invalid: false)
                            let conversation = Conversation(id: accountID + "/" + orgID + "/" + kind.rawValue + "/" + sessionID,
                                sessionID: sessionID, accountID: accountID, organizationID: orgID,
                                title: r["title"].string ?? r["name"].string ?? L10n.tr("Untitled conversation"), kind: kind,
                                modifiedAt: Dates.parse(r["lastActivityAt"]) ?? Dates.parse(r["updatedAt"]) ?? stamp.modified,
                                model: r["model"].string, project: r["cwd"].string,
                                recordRelativePath: relative, cliSessionID: r["cliSessionId"].string,
                                archived: r["isArchived"].bool ?? false, parentSessionID: lineage.parent,
                                invalidLineage: lineage.invalid ? true : nil)
                            conversations.append(conversation); recordCache[relative] = (stamp, conversation)
                        } catch { warnings.append(L10n.tr("A conversation record changed or uses an unsupported format and was skipped.")) }
                    }
                }
            }
        }
        // Multiple organizations require an explicit choice before migration; folders without sessions don't count.
        for (id, all) in allOrganizations {
            let candidates = sessionOrganizations[id] ?? all
            if candidates.count == 1 { accounts[id]?.organizationID = candidates.first }
        }
        for (id, org) in verifiedOrganizations where accounts[id] != nil && UUID(uuidString: org) != nil {
            accounts[id]?.organizationID = org.lowercased()
        }
        recordCache = recordCache.filter { seen.contains($0.key) }
        if let cli = codeAccount(), let id = cli.accountUuid?.lowercased(), accounts[id] != nil {
            accounts[id]?.email = cli.emailAddress
            // Claude Code can be signed in to another organization of the same account, so it only fills a gap.
            if accounts[id]?.organizationID == nil, let org = cli.organizationUuid, UUID(uuidString: org) != nil {
                accounts[id]?.organizationID = org.lowercased()
            }
        }
        let profile = desktopProfile()
        for (id, email) in profile.emails where accounts[id] != nil { accounts[id]?.email = email }
        // The live cache belongs to the signed-in login; entries left by earlier logins are not current for anyone else.
        if let active, let org = accounts[active]?.organizationID, let seen = profile.observedAt[org] {
            accounts[active]?.plan = profile.plans[org]; accounts[active]?.planObservedAt = seen
        }
        let after = try SafeFiles.json(desktop.appendingPathComponent("config.json"))["lastKnownAccountUuid"].string?.lowercased()
        guard after == active else { throw SwitchError.changed }
        let signedIn = await loginState()
        return LocalInventory(activeAccountID: signedIn == false ? nil : active, accounts: accounts.values.sorted { $0.id < $1.id },
                              conversations: conversations, usage: nil, warnings: Array(Set(warnings)).sorted(),
                              lastKnownAccountID: active, signedIn: signedIn,
                              desktopEmails: profile.emails.filter { accounts[$0.key] != nil })
    }

    /// Re-read only when the file changed: Claude Code rewrites it often, and it can run to megabytes.
    private func codeAccount() -> CodeAccount? {
        guard let fd = try? SafeFiles.openRead(codeConfig) else { codeAccountCache = nil; return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        guard let stamp = try? SafeFiles.stamp(fd) else { return nil }
        if let cached = codeAccountCache, cached.stamp == stamp { return cached.account }
        let account = (try? SafeFiles.read(codeConfig)).flatMap { try? JSONDecoder().decode(CodeConfig.self, from: $0).oauthAccount }
        codeAccountCache = (stamp, account)
        return account
    }

    /// Claude rewrites the cookie store in place; a read caught mid-write can miss rows,
    /// so "signed out" must be seen twice in a row.
    private func loginState() async -> Bool? {
        let cookies = desktop.appendingPathComponent("Cookies")
        guard let first = LoginProbe.signedIn(cookies: cookies) else { return nil }
        if first { return true }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        return LoginProbe.signedIn(cookies: cookies)
    }

    private func desktopProfile() -> DesktopProfile.Cache {
        let files = DesktopProfile.files(desktop: desktop)
        let signature = files.map { file -> String in
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return file.path + ":" + String(values?.fileSize ?? -1) + ":" + String(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }.sorted()
        if signature != profileCache.signature { profileCache = (signature, DesktopProfile.read(files: files)) }
        return profileCache.profile
    }

}
