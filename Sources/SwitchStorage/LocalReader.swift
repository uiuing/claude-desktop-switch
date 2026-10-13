import Foundation
import SwitchCore

public actor LocalReader: InventoryReader {
    public let desktop: URL
    public let codeConfig: URL
    public let projects: URL?
    private var recordCache: [String: (FileStamp, Conversation)] = [:]
    private var profileCache: (signature: [String], profile: DesktopProfile.Cache) = ([], DesktopProfile.Cache())
    private var limitLog = LimitLogScanner()
    public init(desktop: URL, codeConfig: URL, projects: URL? = nil) {
        self.desktop = desktop; self.codeConfig = codeConfig; self.projects = projects
    }

    public func scan() async throws -> LocalInventory {
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
                            let conversation = Conversation(id: accountID + "/" + orgID + "/" + kind.rawValue + "/" + sessionID,
                                sessionID: sessionID, accountID: accountID, organizationID: orgID,
                                title: r["title"].string ?? r["name"].string ?? L10n.tr("Untitled conversation"), kind: kind,
                                modifiedAt: Dates.parse(r["lastActivityAt"]) ?? Dates.parse(r["updatedAt"]) ?? stamp.modified,
                                model: r["model"].string, project: r["cwd"].string,
                                recordRelativePath: relative, cliSessionID: r["cliSessionId"].string,
                                archived: r["isArchived"].bool ?? false)
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
        recordCache = recordCache.filter { seen.contains($0.key) }
        if let cli = try? SafeFiles.json(codeConfig), let id = cli["oauthAccount"]["accountUuid"].string?.lowercased(),
           accounts[id] != nil {
            accounts[id]?.email = cli["oauthAccount"]["emailAddress"].string
            if let org = cli["oauthAccount"]["organizationUuid"].string, UUID(uuidString: org) != nil {
                accounts[id]?.organizationID = org.lowercased()
            }
        }
        let profile = desktopProfile()
        for (id, email) in profile.emails where accounts[id] != nil && accounts[id]?.email == nil { accounts[id]?.email = email }
        // The live cache belongs to the signed-in login; entries left by earlier logins are not current for anyone else.
        if let active, let org = accounts[active]?.organizationID, let seen = profile.observedAt[org] {
            accounts[active]?.plan = profile.plans[org]; accounts[active]?.planObservedAt = seen
        }
        let samples = (try? SafeFiles.json(desktop.appendingPathComponent("plan-usage-history.json")))?["samples"].array ?? []
        var hints: [String: [ResetHint]] = [:]
        if let active, let org = accounts[active]?.organizationID { hints[active] = profile.limits[org] ?? [] }
        if let projects {
            // A transcript names only its session; a session copied to several accounts cannot be attributed.
            var owners: [String: Set<String>] = [:]
            for conversation in conversations { if let cli = conversation.cliSessionID { owners[cli, default: []].insert(conversation.accountID) } }
            for (session, found) in limitLog.scan(projects: projects) {
                if let owner = owners[session], owner.count == 1, let id = owner.first { hints[id, default: []] += found }
            }
        }
        var cachedUsage: [String: UsageSnapshot] = [:]
        for account in accounts.values {
            guard let org = account.organizationID,
                  accounts.values.filter({ $0.organizationID == org }).count == 1 else { continue }
            if let reading = localUsage(accountID: account.id, organizationID: org, samples: samples, hints: hints[account.id] ?? []) {
                cachedUsage[account.id] = reading
            }
        }
        let usage = active.flatMap { cachedUsage[$0] }
        if usage == nil { warnings.append(L10n.tr("No quota records can be reliably attributed to the current account.")) }
        let after = try SafeFiles.json(desktop.appendingPathComponent("config.json"))["lastKnownAccountUuid"].string?.lowercased()
        guard after == active else { throw SwitchError.changed }
        let signedIn = await loginState()
        return LocalInventory(activeAccountID: signedIn == false ? nil : active, accounts: accounts.values.sorted { $0.id < $1.id },
                              conversations: conversations, usage: usage, warnings: Array(Set(warnings)).sorted(), cachedUsage: cachedUsage,
                              lastKnownAccountID: active, signedIn: signedIn)
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

    private func localUsage(accountID: String, organizationID: String, samples: [JSONValue],
                            hints: [ResetHint]) -> UsageSnapshot? {
        // A plan-history file can retain samples from the previous login. Never use samples.last blindly.
        let now = Date()
        let keys = [("fh", "five_hour", L10n.quotaTitle("five_hour", fallback: "five_hour")),
                    ("sd", "seven_day", L10n.quotaTitle("seven_day", fallback: "seven_day"))]
        let readings = samples.filter { $0["org"].string?.lowercased() == organizationID }.compactMap { sample -> UsageSample? in
            guard let time = Dates.parse(sample["t"]), time <= now.addingTimeInterval(60) else { return nil }
            var used: [String: Double] = [:]
            for (key, id, _) in keys {
                if let value = sample["u"][key].number, value.isFinite, (0...100).contains(value) { used[id] = value }
            }
            return UsageSample(time: time, used: used)
        }.sorted { $0.time < $1.time }
        guard let latest = readings.last else { return nil }
        var windows: [QuotaWindow] = []
        for (_, id, label) in keys {
            guard let used = latest.used[id] else { continue }
            // Samples carry no reset time: use one Claude recorded at a limit hit, else the latest bound.
            let reset = ResetInference.reset(windowID: id, samples: readings, hints: hints, now: now)
            windows.append(QuotaWindow(id: id, title: label, usedPercent: used, resetsAt: reset?.date,
                                       resetIsEstimate: reset?.isEstimate ?? false))
        }
        guard !windows.isEmpty else { return nil }
        return UsageSnapshot(accountID: accountID, organizationID: organizationID, observedAt: latest.time, origin: .localCache, windows: windows)
    }
}
