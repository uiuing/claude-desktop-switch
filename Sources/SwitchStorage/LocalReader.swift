import Foundation
import SwitchCore

public actor LocalReader: InventoryReader {
    public let desktop: URL
    public let codeConfig: URL
    public let projects: URL?
    private var recordCache: [String: (FileStamp, Conversation)] = [:]
    private var activityCache: [String: (stamp: FileStamp, date: Date?)] = [:]
    private struct ActivityRow: Decodable { var type: String; var timestamp: JSONValue? }
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
                                modifiedAt: kind == .code
                                    ? Dates.parse(r["lastActivityAt"]) ?? Dates.parse(r["updatedAt"]) ?? .distantPast
                                    : [Dates.parse(r["lastActivityAt"]), Dates.parse(r["updatedAt"])].compactMap { $0 }.max() ?? stamp.modified,
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
        conversations = withTranscriptActivity(conversations, activeAccountID: signedIn == false ? nil : active)
        return LocalInventory(activeAccountID: signedIn == false ? nil : active, accounts: accounts.values.sorted { $0.id < $1.id },
                              conversations: conversations, usage: nil, warnings: Array(Set(warnings)).sorted(),
                              lastKnownAccountID: active, signedIn: signedIn,
                              desktopEmails: profile.emails.filter { accounts[$0.key] != nil })
    }

    /// Overlay conversation activity on every scan; transcript appends need not change the cached Desktop index.
    private func withTranscriptActivity(_ conversations: [Conversation], activeAccountID: String?) -> [Conversation] {
        let wanted = Set(conversations.filter { $0.kind == .code && $0.accountID == activeAccountID }.compactMap { session in
            session.cliSessionID.flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }
        })
        guard let projects, !wanted.isEmpty else { activityCache.removeAll(); return conversations }
        var files: [String: [URL]] = [:], budget = 10_000
        func children(_ folder: URL) throws -> [URL] {
            let entries = try SafeFiles.children(folder)
            guard entries.count <= budget else { throw SwitchError.unsafePath }
            budget -= entries.count
            return entries
        }
        do {
            for project in try children(projects) where (try? project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                for file in try children(project) where file.pathExtension == "jsonl" {
                    let id = file.deletingPathExtension().lastPathComponent.lowercased()
                    if wanted.contains(id) { files[id, default: []].append(file) }
                }
            }
        } catch { return conversations }
        let now = Date()
        var seen = Set<String>(), readBudget = 16 * 1024 * 1024
        defer { activityCache = activityCache.filter { seen.contains($0.key) } }
        func activity(_ file: URL) -> Date? {
            seen.insert(file.path)
            guard let fd = try? SafeFiles.openRead(file) else { return nil }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            guard let stamp = try? SafeFiles.stamp(fd), stamp.size > 0, stamp.modified <= now else { return nil }
            if let cached = activityCache[file.path], cached.stamp == stamp { return cached.date }
            // Quit flushes append titles and other maintenance rows to idle histories too.
            // Read only timestamp/type fields from a bounded tail, never message contents.
            let count = Int(min(stamp.size, 1024 * 1024))
            guard count <= readBudget else { return nil }
            readBudget -= count
            let offset = UInt64(stamp.size - Int64(count))
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.read(upToCount: count), data.count == count,
                  (try? SafeFiles.stamp(fd)) == stamp else { return nil }
            let lines = data.split(separator: 10, omittingEmptySubsequences: false).dropFirst(offset > 0 ? 1 : 0)
            let decoder = JSONDecoder()
            let date = lines.compactMap { line -> Date? in
                guard let row = try? decoder.decode(ActivityRow.self, from: Data(line)),
                      row.type == "user" || row.type == "assistant",
                      let timestamp = row.timestamp, let date = Dates.parse(timestamp), date <= now else { return nil }
                return date
            }.max()
            activityCache[file.path] = (stamp, date)
            return date
        }
        var latest: [String: Date] = [:]
        for (id, matches) in files.sorted(by: { $0.key < $1.key }) {
            // Shared histories can have duplicate filenames across projects; never guess which one belongs here.
            guard matches.count == 1, let file = matches.first else { continue }
            var dates = [activity(file)].compactMap { $0 }
            let agents = file.deletingPathExtension().appendingPathComponent("subagents")
            if let entries = try? children(agents) {
                dates += entries.filter {
                    $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("agent-") && !$0.lastPathComponent.contains(".superseded-")
                }.sorted { $0.path < $1.path }.compactMap(activity)
            }
            latest[id] = dates.max()
        }
        return conversations.map { session in
            var result = session
            // Inactive copies retain their own index times; transcripts are shared between accounts.
            if session.kind == .code, session.accountID == activeAccountID,
               let cli = session.cliSessionID, let date = latest[cli.lowercased()] {
                result.modifiedAt = max(session.modifiedAt, date)
            }
            return result
        }
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
