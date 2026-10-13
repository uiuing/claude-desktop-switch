import Foundation
import SwitchCore
import SwitchStorage

public actor SwitchEngine: SwitchService {
    private let environment: MacEnvironment
    private let vault: CredentialVault
    private var busy = false
    private var transactions: URL { environment.root.appendingPathComponent("transactions") }
    public init(environment: MacEnvironment, vault: CredentialVault) { self.environment = environment; self.vault = vault }

    public func prepare(kind: OperationKind, target: Account, sessions: [Conversation] = [],
                        transferModes: [String: SessionTransferMode] = [:]) throws -> OperationPlan {
        guard Set(sessions.map(\.id)).count == sessions.count else { throw SwitchError.malformed(L10n.tr("Duplicate transaction target.")) }
        if kind == .migrate && sessions.isEmpty { throw SwitchError.missing(L10n.tr("No conversations")) }
        let current = try environment.lastKnownAccount()
        let signedIn = current != nil && environment.signedIn() != false
        let steps: [String]
        switch kind {
        case .capture: steps = [L10n.tr("Quit Claude normally and wait for workers to finish"), L10n.tr("Encrypt and save the current login state"), L10n.tr("Reopen Claude")]
        case .switchAccount: steps = [L10n.tr("Verify the target snapshot and current Claude version"), L10n.tr("Quit Claude normally and save the current account's latest login"),
                                      L10n.tr("Write a recovery journal and replace the login container and OAuth cache"), L10n.tr("Bring followed conversations along, replacing older versions in the target account"), L10n.tr("Open Claude and let it verify the login")]
        case .signOut: steps = [L10n.tr("Quit Claude normally and encrypt the current account's login"), L10n.tr("Move the login into Claude Switch without signing out on the server"),
                                L10n.tr("Reopen Claude on its sign-in screen"), L10n.tr("After you sign in to the new account, Claude Switch saves it")]
        case .migrate: steps = [L10n.tr("Quit Claude and verify the conversation records"), L10n.tr("Write the conversations to the target account, replacing older versions"),
                                L10n.tr("Remove or keep the conversations in the original account as selected"), L10n.tr("Reopen Claude")]
        case .recover: throw SwitchError.blocked(L10n.tr("Choose an unfinished transaction to recover."))
        }
        if kind == .capture && target.id != current { throw SwitchError.changed }
        if kind == .signOut && (target.id != current || !signedIn) {
            throw SwitchError.blocked(L10n.tr("Claude is signed out. Just sign in to the account to add in Claude."))
        }
        if kind == .switchAccount && target.id == current && signedIn { throw SwitchError.blocked(L10n.tr("This account is already active.")) }
        var warnings = [L10n.tr("Ongoing work will be interrupted. Finish your work first.")]
        if kind == .switchAccount { warnings.append(L10n.tr("Switching the Desktop login does not change the separate Claude Code CLI login.")) }
        if kind == .signOut {
            warnings = [L10n.tr("Nothing is signed out on the server; the current account can be switched back to at any time."), L10n.tr("Don't change accounts with /login or by signing out in Claude: that voids the saved login of the previous account.")]
        }
        var plan = OperationPlan(kind: kind, sourceAccountID: current, targetAccountID: target.id,
                                 configDigest: try environment.configDigest(), steps: steps,
                                 conversationIDs: sessions.map(\.id), warnings: warnings)
        plan.targetOrganizationID = target.organizationID
        plan.transferModes = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, transferModes[$0.id] ?? .move) })
        for session in sessions {
            if let reason = SessionLibrary.migrationBlocker(session, target: target) { throw SwitchError.blocked(reason) }
            let bytes = try SafeFiles.read(SafeFiles.child(session.recordRelativePath, of: environment.desktop), limit: 2 * 1024 * 1024)
            plan.sourceDigests[session.id] = digest(bytes)
            let relative = try MigrationBuilder.destinationRelative(session: session, target: target)
            plan.destinationExpectations[relative] = try MigrationBuilder.expectation(at: SafeFiles.child(relative, of: environment.desktop))
        }
        if !sessions.isEmpty {
            _ = try MigrationBuilder.changes(sessions: sessions, target: target, environment: environment,
                expectedDigests: plan.sourceDigests, destinations: plan.destinationExpectations, modes: plan.transferModes)
            plan.warnings.append(L10n.tr("This transfers local Code conversations; cloud state, organization permissions and attachments are not transferred."))
        }
        return plan
    }

    public func currentLoginFingerprint() throws -> String {
        try environment.credentialDigest() + ":" + (environment.version ?? "")
    }

    /// Reads Claude's login files while Claude keeps running and seals them into Switch's own vault.
    /// Nothing under Claude's data directory is opened for writing.
    public func saveCurrentLogin() async throws -> (accountID: String, fingerprint: String) {
        guard !busy else { throw SwitchError.busy }
        busy = true; defer { busy = false }
        guard let version = environment.version else { throw SwitchError.missing(L10n.tr("Claude Desktop was not found.")) }
        guard environment.signedIn() == true else { throw SwitchError.blocked(L10n.tr("Claude is signed out; nothing was saved.")) }
        let before = try currentLoginFingerprint()
        let snapshot = try capture(version: version)
        // A token refresh or account change during the read leaves a mixed snapshot; skip and retry later.
        guard try currentLoginFingerprint() == before, try environment.currentAccount() == snapshot.accountID else {
            throw SwitchError.changed
        }
        try await vault.save(snapshot)
        return (snapshot.accountID, before)
    }

    /// Profile cached in a saved login's own claude.ai IndexedDB.
    public func savedProfile(accountID: String) async -> DesktopProfile.Cache? {
        guard let snapshot = try? await vault.load(accountID: accountID) else { return nil }
        var result = DesktopProfile.Cache()
        let blobs = snapshot.files.filter { $0.path.hasPrefix(DesktopProfile.blobDirectory + "/") }
        for file in blobs.sorted(by: { DesktopProfile.blobNumber($0.path) > DesktopProfile.blobNumber($1.path) }) {
            result.merge(DesktopProfile.read(file.data, observedAt: snapshot.createdAt))
        }
        return result
    }

    /// Deletes every copy Switch holds of an account's login: the vault and its share of finished transactions.
    /// Unfinished transactions stay untouched; they are the way back from an interrupted switch.
    public func removeLogin(accountID: String) async throws {
        guard !busy else { throw SwitchError.busy }
        busy = true; defer { busy = false }
        try await purge(accountID: accountID)
    }
    /// Logins a build that moved removals aside left behind are deleted as the user asked back then.
    public func purgeMovedAsideLogins() async throws {
        guard !busy else { return }
        busy = true; defer { busy = false }
        for (id, removedAt) in await vault.movedAsideAccounts() {
            // Signed in and saved again since: only what predates the removal goes.
            if await vault.contains(accountID: id) {
                try await purgeTransactions(accountID: id, before: removedAt)
                try await vault.clearMovedAside(accountID: id)
            } else { try await purge(accountID: id) }
        }
    }
    private func purge(accountID: String) async throws {
        guard let id = UUID(uuidString: accountID)?.uuidString.lowercased() else { throw SwitchError.unsafePath }
        try await vault.remove(accountID: id)
        try await purgeTransactions(accountID: id, before: nil)
        try await vault.finishRemoval(accountID: id)
    }
    private func purgeTransactions(accountID id: String, before cutoff: Date?) async throws {
        var failure: Error?
        for directory in (try? SafeFiles.children(transactions)) ?? [] {
            guard UUID(uuidString: directory.lastPathComponent) != nil,
                  let transaction = try? FileTransaction(existing: directory, live: environment.desktop),
                  ["committed", "recovered"].contains(transaction.journal.phase),
                  cutoff.map({ transaction.journal.createdAt < $0 }) ?? true else { continue }
            var parts = Set<String>()
            if transaction.journal.targetAccountID == id { parts.formUnion(["staged", "quarantine"]) }
            if transaction.journal.sourceAccountID == id { parts.insert("originals") }
            guard !parts.isEmpty else { continue }
            do { try await transaction.purge(parts, vault: vault) } catch { failure = failure ?? error }
        }
        if let failure {
            let reason = (failure as? SwitchError)?.localizedDescription ?? failure.localizedDescription
            throw SwitchError.blocked(L10n.tr("The saved login was deleted, but not every backup copy could be deleted: {0}", L10n.argument(reason)))
        }
    }

    /// Accounts without a saved login that Switch can still rebuild from the originals a switch or
    /// sign-out archived when it moved that account's login out of Claude.
    public func recoverableLogins() async -> Set<String> {
        var missing = Set<String>()
        for (journal, _) in archivedLogins() {
            guard let id = journal.sourceAccountID, UUID(uuidString: id) != nil else { continue }
            if !(await vault.contains(accountID: id)) { missing.insert(id) }
        }
        return missing
    }
    private func archivedLogins() -> [(TransactionJournal, URL)] {
        let directories = (try? SafeFiles.children(transactions)) ?? []
        return directories.compactMap { directory -> (TransactionJournal, URL)? in
            guard UUID(uuidString: directory.lastPathComponent) != nil,
                  let transaction = try? FileTransaction(existing: directory, live: environment.desktop),
                  transaction.journal.phase == "committed", transaction.journal.sourceAccountID != nil,
                  !transaction.sourcePurged else { return nil }
            let archive = directory.appendingPathComponent("recovery.switchbackup")
            return FileManager.default.fileExists(atPath: archive.path) ? (transaction.journal, archive) : nil
        }.sorted { $0.0.createdAt > $1.0.createdAt }
    }

    /// Rebuilds the saved login of an account from the newest copy Switch kept. Claude is not touched.
    public func restoreLogin(accountID: String) async throws {
        guard !busy else { throw SwitchError.busy }
        busy = true; defer { busy = false }
        guard let id = UUID(uuidString: accountID)?.uuidString.lowercased() else { throw SwitchError.unsafePath }
        guard let version = environment.version else { throw SwitchError.missing(L10n.tr("Claude Desktop was not found.")) }
        for (journal, archive) in archivedLogins() where journal.sourceAccountID == id {
            guard let sealed = try? SafeFiles.read(archive, limit: 192 * 1024 * 1024),
                  let data = try? await vault.unseal(sealed, context: "transaction:" + journal.id),
                  let archived = try? JSONDecoder().decode([ArchiveFile].self, from: data) else { continue }
            // Originals are what Claude held right before the login was swapped out.
            let originals = archived.filter { $0.path.hasPrefix("originals/") && digest($0.data) == $0.sha256 }
                .map { ArchiveFile(path: String($0.path.dropFirst("originals/".count)), data: $0.data, sha256: $0.sha256) }
            guard let stored = originals.first(where: { $0.path == "config.json" })?.data,
                  let config = try? MacEnvironment.effectiveConfig(stored: stored,
                      journal: originals.first(where: { $0.path == "config.json.journal" })?.data),
                  (try? IdentitySchema.validateConfig(config)) != nil,
                  config["lastKnownAccountUuid"].string?.lowercased() == id else { continue }
            let files = originals.filter { file in IdentitySchema.containers.contains { file.path == $0 || file.path.hasPrefix($0 + "/") } }
            guard let cookies = files.first(where: { $0.path == "Cookies" }), LoginProbe.signedIn(cookieData: cookies.data) == true
            else { continue }
            var directories = Set<String>()
            for file in files {
                let parts = file.path.split(separator: "/").dropLast()
                for depth in parts.indices { directories.insert(parts[...depth].joined(separator: "/")) }
            }
            guard directories.contains("Local Storage") else { continue }
            try await vault.save(LoginSnapshot(accountID: id, version: version, createdAt: journal.createdAt,
                auth: (config.object ?? [:]).filter { IdentitySchema.configKeys.contains($0.key) },
                files: files, directories: directories.sorted()))
            return
        }
        throw SwitchError.missing(L10n.tr("No restorable copy of this account's login was found."))
    }

    public func pendingRecovery() throws -> [String] {
        guard FileManager.default.fileExists(atPath: transactions.path) else { return [] }
        return try SafeFiles.children(transactions).compactMap { directory in
            guard UUID(uuidString: directory.lastPathComponent) != nil else { return nil }
            let transaction = try FileTransaction(existing: directory, live: environment.desktop)
            return ["committed", "recovered", "preparing"].contains(transaction.journal.phase) ? nil : directory.lastPathComponent
        }
    }

    public func execute(_ plan: OperationPlan, confirmedPlanID: UUID, target: Account,
                        sessions: [Conversation]) async throws -> String {
        try BuildAccess.requireClaudeWrites()
        guard !busy else { throw SwitchError.busy }
        guard plan.kind != .recover else { throw SwitchError.blocked(L10n.tr("Use the recovery entry point to recover operations.")) }
        guard confirmedPlanID == plan.id, target.id == plan.targetAccountID,
              target.organizationID == plan.targetOrganizationID,
              Set(sessions.map(\.id)) == Set(plan.conversationIDs) else { throw SwitchError.changed }
        busy = true; defer { busy = false }
        let operationLock = try OperationLock(root: environment.root)
        defer { withExtendedLifetime(operationLock) {} }
        guard try pendingRecovery().isEmpty else { throw SwitchError.blocked(L10n.tr("An unfinished transaction exists. Recover it first.")) }
        // Claude rewrites config.json while it runs. A switch re-checks the signed-in account below and
        // every followed session against its own digest, so only other kinds pin the whole file.
        let swapsLogin = plan.kind == .switchAccount || plan.kind == .signOut
        if swapsLogin {
            guard UUID(uuidString: plan.targetAccountID) != nil else { throw SwitchError.malformed(L10n.tr("Account identity information is incomplete.")) }
        } else { try plan.validate(digest: environment.configDigest()) }
        guard try environment.lastKnownAccount() == plan.sourceAccountID,
              let application = environment.application, let version = environment.version else { throw SwitchError.changed }
        let targetSnapshot = plan.kind == .switchAccount ? try await vault.load(accountID: target.id) : nil
        if let targetSnapshot, targetSnapshot.version != version {
            throw SwitchError.blocked(L10n.tr("The target snapshot is from a different Claude version. Save that account again before switching."))
        }
        let changes = try MigrationBuilder.changes(sessions: sessions, target: target, environment: environment,
            expectedDigests: plan.sourceDigests, destinations: plan.destinationExpectations, modes: plan.transferModes)
        let desktop = await DesktopController()
        let wasRunning = try await desktop.quitGracefully()
        // Exiting writes some config fields. Revalidate identity, not the pre-quit whole-file hash.
        guard try environment.lastKnownAccount() == plan.sourceAccountID else { throw SwitchError.changed }
        try await desktop.waitUntilStopped()
        if plan.kind == .capture {
            let snapshot = try capture(version: version)
            try await vault.save(snapshot)
            if wasRunning { try await desktop.launch(application) }
            return L10n.tr("The current login snapshot has been encrypted and saved.")
        }
        // A signed-out login is worthless and must not replace the account's saved one.
        let sourceSignedIn = plan.sourceAccountID != nil && environment.signedIn() == true
        if plan.kind == .signOut && !sourceSignedIn {
            if wasRunning { try? await desktop.launch(application) }
            throw SwitchError.blocked(L10n.tr("Claude is signed out. Just sign in to the account to add in Claude."))
        }
        if swapsLogin && sourceSignedIn {
            do { try await vault.save(capture(version: version)) }
            catch { if wasRunning { try? await desktop.launch(application) }; throw error }
        }
        let transaction = try FileTransaction(parent: transactions, live: environment.desktop, plan: plan)
        do {
            if swapsLogin {
                // Signing out installs an empty identity: Claude's login moves into the vault, nothing else is touched.
                for container in IdentitySchema.containers {
                    if let targetSnapshot {
                        try transaction.stageContainer(container, files: targetSnapshot.files, directories: targetSnapshot.directories)
                    } else if FileManager.default.fileExists(atPath: environment.desktop.appendingPathComponent(container).path) {
                        try transaction.stage(relative: container, data: nil)
                    }
                }
                guard var object = try environment.effectiveConfig().object else {
                    throw SwitchError.malformed(L10n.tr("Could not parse login settings. Stopped."))
                }
                for key in IdentitySchema.configKeys { object.removeValue(forKey: key) }
                for (key, value) in targetSnapshot?.auth ?? [:] where IdentitySchema.configKeys.contains(key) { object[key] = value }
                try transaction.stage(relative: "config.json", data: JSONEncoder().encode(JSONValue.object(object)))
                // Its payload is folded into the new config.json above; left behind it would carry the old login.
                if FileManager.default.fileExists(atPath: environment.configJournal.path) {
                    try transaction.stage(relative: "config.json.journal", data: nil)
                }
            }
            // Re-read after shutdown: a session still changing during the preview must be re-reviewed.
            let finalChanges = try MigrationBuilder.changes(sessions: sessions, target: target, environment: environment,
                expectedDigests: plan.sourceDigests, destinations: plan.destinationExpectations, modes: plan.transferModes)
            guard changes.map(\.relative) == finalChanges.map(\.relative) else { throw SwitchError.changed }
            for change in finalChanges {
                try transaction.stage(relative: change.relative, data: change.data, expectation: change.expectation)
            }
            try await transaction.apply { try await desktop.waitUntilStopped() }
            if plan.kind == .switchAccount, try environment.currentAccount() != target.id { throw SwitchError.changed }
            if plan.kind == .signOut, try environment.lastKnownAccount() != nil { throw SwitchError.changed }
            try transaction.commit()
        } catch {
            let reason = (error as? SwitchError)?.localizedDescription ?? error.localizedDescription
            do { try await transaction.rollback { try await desktop.waitUntilStopped() } }
            catch { throw SwitchError.blocked(L10n.tr("The transaction is unfinished and needs manual recovery. Originals and the recovery journal are preserved. Use recovery in Settings.")) }
            try? await transaction.archive(vault: vault)
            // Every original is back in place, so the previous login is safe to reopen.
            if wasRunning, (try? await desktop.launch(application)) != nil {
                throw SwitchError.blocked(L10n.tr("The switch did not finish. The previous login was restored and Claude was reopened. Reason: {0}", L10n.argument(reason)))
            }
            throw SwitchError.blocked(L10n.tr("The operation stopped and the original files were restored. Reason: {0}. Please open Claude manually.", L10n.argument(reason)))
        }
        var archiveNotice = ""
        do { try await transaction.archive(vault: vault) }
        catch { archiveNotice = L10n.tr(" Recovery copies remain in the protected local transaction folder; encrypted archiving is not yet complete.") }
        if wasRunning || swapsLogin {
            do { try await desktop.launch(application) }
            catch { return L10n.tr("Data was applied, but Claude could not reopen automatically. Recovery data is preserved. Open Claude manually and verify the login.") + archiveNotice }
        }
        switch plan.kind {
        case .migrate: return L10n.tr("Conversations transferred as selected. Confirm that they resume in Claude.") + archiveNotice
        case .signOut: return L10n.tr("The previous account was saved and moved out of Claude. Sign in to the account to add in Claude; it will be saved.") + archiveNotice
        default: return L10n.tr("The target login snapshot was loaded. Claude still needs to verify the login.") + archiveNotice
        }
    }

    public func recover(transactionID: String) async throws {
        try BuildAccess.requireClaudeWrites()
        guard !busy, UUID(uuidString: transactionID) != nil else { throw SwitchError.busy }
        busy = true; defer { busy = false }
        let operationLock = try OperationLock(root: environment.root)
        defer { withExtendedLifetime(operationLock) {} }
        let desktop = await DesktopController()
        try await desktop.assertStopped()
        let transaction = try FileTransaction(existing: transactions.appendingPathComponent(transactionID), live: environment.desktop)
        guard !["committed", "recovered"].contains(transaction.journal.phase) else {
            throw SwitchError.blocked(L10n.tr("This transaction has ended. Data created afterwards will not be overwritten."))
        }
        try await transaction.rollback { try await desktop.assertStopped() }
        try await transaction.archive(vault: vault)
    }

    private func capture(version: String) throws -> LoginSnapshot {
        let config = try environment.effectiveConfig()
        try IdentitySchema.validateConfig(config)
        let account = try environment.currentAccount()
        var files: [ArchiveFile] = [], directories: [String] = [], total = 0
        func visit(_ url: URL, relative: String, depth: Int) throws {
            guard depth <= 16, files.count < 20_000 else { throw SwitchError.blocked(L10n.tr("The login container exceeds the safe scan limit.")) }
            try SafeFiles.validateAncestors(url)
            let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
            guard info.isSymbolicLink != true else { throw SwitchError.unsafePath }
            if info.isDirectory == true {
                directories.append(relative)
                // Include dotfiles in identity stores; directory listings for session discovery may skip them.
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    try visit(child, relative: relative + "/" + child.lastPathComponent, depth: depth + 1)
                }
            } else {
                guard info.isRegularFile == true else { throw SwitchError.unsafePath }
                let data = try SafeFiles.read(url, limit: 64 * 1024 * 1024)
                total += data.count
                guard total <= 128 * 1024 * 1024 else { throw SwitchError.blocked(L10n.tr("The login snapshot exceeds 128 MB. Original data was not changed.")) }
                files.append(ArchiveFile(path: relative, data: data, sha256: digest(data)))
            }
        }
        for name in IdentitySchema.containers {
            let url = environment.desktop.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try visit(url, relative: name, depth: 0) }
        }
        guard let cookies = files.first(where: { $0.path == "Cookies" }), directories.contains("Local Storage") else {
            throw SwitchError.blocked(L10n.tr("The login container does not match the current adapter. A recoverable snapshot cannot be created."))
        }
        guard LoginProbe.signedIn(cookieData: cookies.data) == true else {
            throw SwitchError.blocked(L10n.tr("Claude is signed out; nothing was saved."))
        }
        return LoginSnapshot(accountID: account, version: version, createdAt: Date(),
                             auth: (config.object ?? [:]).filter { IdentitySchema.configKeys.contains($0.key) },
                             files: files, directories: directories)
    }
}
