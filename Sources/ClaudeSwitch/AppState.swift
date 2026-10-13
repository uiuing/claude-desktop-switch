import AppKit
import Foundation
import SwiftUI
import SwitchCore
import SwitchStorage
import SwitchMac

enum NavigationPage: String, CaseIterable, Identifiable {
    case accounts = "Accounts", conversations = "Conversations", usage = "Usage", settings = "Settings"
    var id: String { rawValue }
    var title: String { L10n.tr(rawValue) }
    static let primary: [NavigationPage] = [.accounts, .conversations, .usage]
    var symbol: String {
        switch self {
        case .accounts: return "person.2"
        case .conversations: return "bubble.left.and.text.bubble.right"
        case .usage: return "chart.bar.xaxis"
        case .settings: return "gearshape"
        }
    }
}
struct PendingOperation: Identifiable {
    var id: UUID { plan.id }
    var plan: OperationPlan
    var target: Account
    var sessions: [Conversation]
}

@MainActor
final class AppState: ObservableObject {
    @Published var page: NavigationPage = .accounts
    @Published var library = LibraryState()
    @Published var inventory: LocalInventory?
    @Published var tokenReport = TokenReport()
    @Published var tokenDays = 0
    @Published var analytics = UsageAnalytics()
    @Published var tokenScanError: String?
    @Published var tokenInitialScan = true
    @Published var refreshing = false
    @Published var usageRefreshingAccountID: String?
    @Published var usageErrors: [String: String] = [:]
    /// Why the last live read was skipped while the login is merely not readable yet; shown only on hover.
    @Published var usageNotices: [String: String] = [:]
    @Published var scanningTokens = false
    @Published var working = false
    @Published var message: String?
    @Published var pending: PendingOperation?
    @Published var search = ""
    @Published var selectedSessionIDs = Set<String>()
    @Published var sessionFilter: SessionKind?
    @Published var selectedAccountID: String?
    @Published var showSessionInspector = true
    @Published var showAddAccount = false
    @Published var showQuickFind = false
    @Published var recoveryIDs: [String] = []
    @Published var tokenScanDone = false
    @Published var savingLogin = false
    @Published var loginSaveError: String?
    private var failedLoginFingerprint: String?
    let demo: Bool
    let environment = MacEnvironment()
    private let store: LibraryStore
    private let reader: LocalReader
    private let tokens: TokenScanner
    private let vault: CredentialVault
    private let engine: SwitchEngine
    private let usageClient: ActiveUsageClient
    private var started = false
    private var libraryReadable = true
    private var polling: Task<Void, Never>?
    private var profileLookups = Set<String>()
    private var lastSignedInID: String?
    @Published private var quotaProjections: [String: QuotaProjection] = [:]
    @Published private var transferChoices: [String: SessionTransferMode] = [:]
    private var projectionGeneration = UUID()

    init(demo: Bool = ProcessInfo.processInfo.arguments.contains("--demo")) {
        self.demo = demo
        let env = MacEnvironment()
        store = LibraryStore(root: env.root)
        reader = LocalReader(desktop: env.desktop, codeConfig: env.codeConfig, projects: env.projects)
        tokens = TokenScanner(projects: env.projects, cacheURL: env.root.appendingPathComponent("usage-cache.json"))
        let vault = CredentialVault(root: env.root.appendingPathComponent("vault"))
        self.vault = vault
        engine = SwitchEngine(environment: env, vault: vault)
        usageClient = ActiveUsageClient(environment: env)
        if demo {
            let data = DemoData.make()
            library = data.library; inventory = data.inventory; tokenReport = data.tokens; analytics = data.analytics
            tokenScanDone = true
        }
        Task { [weak self] in await self?.start() }
    }
    var activeID: String? { inventory?.activeAccountID }
    /// Accounts saved in Switch. Claude's local data only decides which of them is signed in.
    var accounts: [Account] { knownAccounts.filter(\.hasSnapshot) }
    /// The Claude Desktop login is known but Switch has not saved it (yet).
    var activeUnsaved: Bool { !demo && activeID != nil && activeAccount == nil }
    /// Claude shows its sign-in screen, whether Switch moved the login out or the server rejected it.
    var claudeSignedOut: Bool { !demo && inventory?.signedIn == false }
    /// Every account Claude Desktop has left on this Mac. Only used to attribute sessions.
    var knownAccounts: [Account] {
        var merged = Dictionary(library.accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for discovered in inventory?.accounts ?? [] {
            if var stored = merged[discovered.id] {
                stored.email = discovered.email ?? stored.email
                if let organization = discovered.organizationID {
                    stored.setOrganization(organization)
                    if let seen = discovered.planObservedAt {
                        stored.observePlan(discovered.plan, organizationID: organization, at: seen)
                    }
                }
                merged[stored.id] = stored
            } else { merged[discovered.id] = discovered }
        }
        return merged.values.sorted {
            if ($0.id == activeID) != ($1.id == activeID) { return $0.id == activeID }
            return ($0.email ?? "~" + $0.id).localizedStandardCompare($1.email ?? "~" + $1.id) == .orderedAscending
        }
    }
    func identity(_ account: Account) -> String { account.identity(maskingEmail: library.preferences.maskEmail) }
    func identity(id: String) -> String { knownAccounts.first { $0.id == id }.map(identity) ?? L10n.tr("Unassigned account") }
    var activeAccount: Account? { accounts.first { $0.id == activeID } }
    var unarchivedSessions: [Conversation] { (inventory?.conversations ?? []).filter { !$0.archived } }
    var selectedSessions: [Conversation] { unarchivedSessions.filter { selectedSessionIDs.contains($0.id) } }
    var sessions: [Conversation] {
        let filtered = unarchivedSessions.filter { session in
            (sessionFilter == nil || session.kind == sessionFilter) &&
            (selectedAccountID == nil || selectedAccountID == session.accountID) &&
            (search.isEmpty || session.title.localizedStandardContains(search) ||
             (session.project ?? "").localizedStandardContains(search) || identity(id: session.accountID).localizedStandardContains(search))
        }
        return SessionLibrary.sorted(filtered, order: library.preferences.sessionSort, accounts: knownAccounts)
    }
    var canExecute: Bool { BuildAccess.allowsClaudeWrites && !demo && !working && libraryReadable }
    var currentUsage: UsageSnapshot? { activeID.flatMap { library.usage[$0] } }
    func quotaRows(for accountID: String, now: Date = Date()) -> [QuotaReadout] {
        let snapshot = library.usage[accountID]
        var projections: [String: QuotaProjection] = [:]
        for window in snapshot?.windows ?? [] {
            projections[window.id] = quotaProjections[accountID + ":" + window.id]
        }
        return AccountQuotaPresentation.rows(accountID: accountID, snapshot: snapshot,
            active: accountID == activeID, projections: projections, now: now)
    }
    func quotaUpdated(for accountID: String, now: Date = Date()) -> String {
        guard let snapshot = library.usage[accountID], snapshot.accountID == accountID else { return L10n.tr("No quota data yet") }
        guard snapshot.observedAt <= now.addingTimeInterval(60) else { return L10n.tr("Update time unknown") }
        return L10n.tr("Updated {0}", Format.age(snapshot.observedAt, now: now))
    }
    /// A saved account to move to when the signed-in one is about to run out.
    func switchAdvice(now: Date = Date()) -> (account: Account, advice: SwitchAdvice)? {
        guard let activeID else { return nil }
        let others = accounts.filter { $0.id != activeID && $0.hasSnapshot && $0.loginInvalidAt == nil }
        guard let advice = SwitchAdvisor.advice(active: quotaRows(for: activeID, now: now),
                                                candidates: others.map { ($0.id, quotaRows(for: $0.id, now: now)) }, now: now),
              let account = others.first(where: { $0.id == advice.accountID }) else { return nil }
        return (account, advice)
    }
    var fiveHourQuota: QuotaReadout? {
        activeID.flatMap { id in quotaRows(for: id).first { $0.id == "five_hour" } }
    }
    func extraQuotaRows(for accountID: String, now: Date) -> [QuotaReadout] {
        guard let snapshot = library.usage[accountID], snapshot.accountID == accountID else { return [] }
        return snapshot.windows.filter { !["five_hour", "seven_day"].contains($0.id) }.map { window in
            QuotaReadout.make(id: window.id, title: L10n.quotaTitle(window.id, fallback: window.title), window: window, snapshot: snapshot,
                active: accountID == activeID, projection: quotaProjections[accountID + ":" + window.id], now: now)
        }
    }
    func projection(_ window: QuotaWindow, snapshot: UsageSnapshot, active: Bool) -> QuotaProjection {
        quotaProjections[snapshot.accountID + ":" + window.id] ?? QuotaEstimator.project(window, snapshot: snapshot, active: active)
    }
    private func updateProjections() async {
        let generation = UUID(); projectionGeneration = generation
        let snapshots = library.usage, histories = library.usageHistory, report = tokenReport, active = activeID
        let result = await Task.detached(priority: .utility) {
            var values: [String: QuotaProjection] = [:]
            for snapshot in snapshots.values {
                for window in snapshot.windows {
                    values[snapshot.accountID + ":" + window.id] = QuotaCalibrator.projection(window: window,
                        snapshot: snapshot, history: histories[snapshot.accountID] ?? [], report: report, active: snapshot.accountID == active)
                }
            }
            return values
        }.value
        if generation == projectionGeneration { quotaProjections = result }
    }
    private func acceptUsage(_ incoming: UsageSnapshot) {
        let snapshot = incoming.retainingKnownResets(from: library.usage[incoming.accountID])
        library.usage[snapshot.accountID] = snapshot
        quotaProjections = quotaProjections.filter { !$0.key.hasPrefix(snapshot.accountID + ":") }
        var history = library.usageHistory[snapshot.accountID] ?? []
        if history.last?.observedAt != snapshot.observedAt { history.append(snapshot) }
        library.usageHistory[snapshot.accountID] = Array(history.suffix(128))
    }
    func follows(_ id: String) -> Bool {
        guard let session = inventory?.conversations.first(where: { $0.id == id }) else {
            return library.follows.contains { $0.conversationID == id }
        }
        return library.follows.contains { $0.matches(session) }
    }
    /// One choice per session, shared by following and by transferring it now. Moving is the default.
    func transferMode(_ session: Conversation) -> SessionTransferMode {
        library.follows.first { $0.matches(session) }?.transferMode ?? transferChoices[session.sessionID] ?? .move
    }
    /// The common choice of several sessions, or nil when they differ.
    func transferMode(_ sessions: [Conversation]) -> SessionTransferMode? {
        let modes = Set(sessions.map(transferMode))
        return modes.count == 1 ? modes.first : nil
    }
    func setTransferMode(_ mode: SessionTransferMode, sessions: [Conversation]) {
        var followed = false
        for session in sessions {
            transferChoices[session.sessionID] = mode
            for index in library.follows.indices where library.follows[index].matches(session) {
                library.follows[index].sessionID = session.sessionID
                library.follows[index].transferMode = mode
                followed = true
            }
        }
        if followed { persist() }
    }
    /// The target already holds this session, so the transfer replaces it with the current version.
    func replacesExisting(_ session: Conversation, in operation: PendingOperation) -> Bool {
        guard let org = operation.plan.targetOrganizationID else { return false }
        let relative = "claude-code-sessions/\(operation.target.id)/\(org)/\(session.sessionID).json"
        guard let expectation = operation.plan.destinationExpectations[relative] else { return false }
        return expectation != .absent
    }

    func start() async {
        guard !started else { return }; started = true
        guard !demo else { return }
        do { library = try await store.load() }
        catch { libraryReadable = false; message = L10n.tr("Could not read the Switch library. Settings changed in this session will not be saved.") }
        Task { [weak self] in await self?.scanTokens() }
        do { try await engine.purgeMovedAsideLogins() } catch { message = display(error) }
        await refresh()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                guard let self else { return }
                await self.refresh()
                await self.scanTokens()
            }
        }
    }
    func refresh() async {
        guard !refreshing, !working else { return }
        if demo { return }
        refreshing = true; defer { refreshing = false }
        do {
            let result = try await reader.scan()
            var changed = false
            inventory = result
            selectedSessionIDs.formIntersection(unarchivedSessions.map(\.id))
            if let id = result.activeAccountID {
                // Claude Desktop now signs in another account, through Switch or not.
                if let last = lastSignedInID, last != id { Task { await refreshLive(trigger: .accountChanged(id)) } }
                lastSignedInID = id
            }
            for usage in result.cachedUsage.values {
                // A reset time can arrive without a new usage sample, e.g. from a limit hit in a transcript.
                let stored = library.usage[usage.accountID]
                let newer = stored.map { $0.observedAt < usage.observedAt ||
                    ($0.observedAt == usage.observedAt && $0.origin == .localCache && usage.retainingKnownResets(from: $0) != $0) } ?? true
                if newer {
                    acceptUsage(usage)
                    changed = true
                }
            }
            let now = Date()
            for (id, snapshot) in library.usage {
                let rolled = snapshot.rollingOverElapsedResets(now: now)
                if rolled != snapshot { library.usage[id] = rolled; changed = true }
            }
            var updated = knownAccounts
            for index in updated.indices {
                updated[index].hasSnapshot = await vault.contains(accountID: updated[index].id)
                let id = updated[index].id
                if updated[index].hasSnapshot, id != activeID, updated[index].email == nil || updated[index].planObservedAt == nil,
                   profileLookups.insert(id).inserted, let profile = await engine.savedProfile(accountID: id) {
                    updated[index].email = updated[index].email ?? profile.emails[id]
                    if let org = updated[index].organizationID, let seen = profile.observedAt[org] {
                        updated[index].observePlan(profile.plans[org], organizationID: org, at: seen)
                    }
                }
            }
            // Claude keeps naming an account after it is signed out of it, by the user or by a server that
            // rejected the login. That login is void; a session Claude keeps alive proves the opposite.
            if let id = result.lastKnownAccountID, let index = updated.firstIndex(where: { $0.id == id }) {
                if result.signedIn == false, updated[index].loginInvalidAt == nil { updated[index].loginInvalidAt = now }
                if result.signedIn == true { updated[index].loginInvalidAt = nil }
            }
            if library.accounts != updated { library.accounts = updated; changed = true }
            recoveryIDs = try await engine.pendingRecovery()
            recoverableLogins = await engine.recoverableLogins()
                .filter { id in !updated.contains { $0.id == id && $0.hasSnapshot } }.sorted()
            if changed { persist() }
            await updateProjections()
        } catch is CancellationError {
        } catch { message = display(error) }
        await saveCurrentLogin()
    }
    /// Keeps the signed-in account's saved login current. Only Switch's own vault is written.
    func saveCurrentLogin(retry: Bool = false) async {
        guard !demo, libraryReadable, !savingLogin, !working, let activeID else { return }
        guard let fingerprint = try? await engine.currentLoginFingerprint() else { return }
        let stored = knownAccounts.first { $0.id == activeID }
        if stored?.hasSnapshot == true && stored?.snapshotFingerprint == fingerprint { loginSaveError = nil; return }
        if !retry && failedLoginFingerprint == fingerprint { return }
        savingLogin = true; defer { savingLogin = false }
        do {
            let saved = try await engine.saveCurrentLogin()
            var all = knownAccounts
            guard let index = all.firstIndex(where: { $0.id == saved.accountID }) else { return }
            let added = !all[index].hasSnapshot
            all[index].hasSnapshot = true; all[index].lastSavedAt = Date(); all[index].snapshotFingerprint = saved.fingerprint
            all[index].loginInvalidAt = nil
            library.accounts = all; loginSaveError = nil; failedLoginFingerprint = nil
            persist()
            if added { Task { await refreshLive(trigger: .accountChanged(saved.accountID)) } }
        } catch {
            failedLoginFingerprint = fingerprint
            loginSaveError = display(error)
        }
    }
    func canRemove(_ account: Account) -> Bool { account.id != activeID && !working }
    /// Forgets an account in Switch only: its saved login and quota history. Claude is not touched.
    func remove(_ account: Account) async {
        guard canRemove(account) else { return }
        if !demo {
            do { try await engine.removeLogin(accountID: account.id) }
            catch { message = display(error); return }
        }
        library.accounts.removeAll { $0.id == account.id }
        library.usage[account.id] = nil
        library.usageHistory[account.id] = nil
        for index in library.follows.indices { library.follows[index].targetAccountIDs.removeAll { $0 == account.id } }
        recoverableLogins.removeAll { $0 == account.id }
        persist()
    }
    func persist() {
        guard !demo, libraryReadable else { return }
        let state = library
        Task { do { try await store.save(state) } catch { message = L10n.tr("Could not save settings.") } }
    }
    enum LiveTrigger: Equatable { case manual, accountChanged(String) }
    /// Rescans Claude's local records, then asks the server about the signed-in account.
    func refreshNow() async {
        await refresh()
        await refreshLive()
    }
    /// Reads the server's quota for the signed-in account only: on request, and once after it changes or is added.
    func refreshLive(trigger: LiveTrigger = .manual) async {
        guard !demo, !working, usageRefreshingAccountID == nil else { return }
        let accountID: String
        switch trigger {
        case .manual: guard let activeID else { return }; accountID = activeID
        case .accountChanged(let id): accountID = id
        }
        usageRefreshingAccountID = accountID
        defer { usageRefreshingAccountID = nil }
        if trigger == .manual { usageErrors[accountID] = nil; usageNotices[accountID] = nil }
        // A switched-in login is renewed by Claude itself after it starts; wait locally rather than asking early.
        let deadline = Date().addingTimeInterval(trigger == .manual ? 0 : 120)
        while true {
            do {
                guard activeID == accountID else { throw UsageNotReady(message: SwitchError.changed.localizedDescription) }
                let snapshot = try await usageClient.fetchCurrent(accountID: accountID, allowKeychainPrompt: trigger == .manual)
                guard activeID == snapshot.accountID else { return }
                acceptUsage(snapshot)
                usageErrors[accountID] = nil; usageNotices[accountID] = nil
                if let identity = await usageClient.identity(), let index = library.accounts.firstIndex(where: { $0.id == identity.id }) {
                    library.accounts[index].email = identity.email ?? library.accounts[index].email
                    if let organization = identity.organizationID { library.accounts[index].setOrganization(organization) }
                }
                if let verified = await usageClient.takeVerifiedPlan(),
                   let index = library.accounts.firstIndex(where: { $0.id == verified.accountID }) {
                    library.accounts[index].observePlan(verified.plan, organizationID: verified.organizationID, at: verified.observedAt)
                }
                persist()
                await updateProjections()
                return
            } catch is UsageNotReady where Date() < deadline {
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            } catch let notReady as UsageNotReady {
                usageNotices[accountID] = notReady.message
                return
            } catch is UsageCoolingDown where trigger != .manual {
                return
            } catch {
                usageErrors[accountID] = (error as? UsageCoolingDown)?.errorDescription ?? display(error)
                return
            }
        }
    }
    private func acceptAnalytics(_ report: UsageAnalytics) {
        analytics = report; tokenScanDone = true
    }
    func scanTokens() async {
        guard !demo, !scanningTokens else { return }
        tokenInitialScan = !tokenScanDone
        scanningTokens = true; tokenScanError = nil
        defer { scanningTokens = false; tokenInitialScan = false }
        if !tokenScanDone, let cached = await tokens.cachedAnalytics() {
            analytics = cached; tokenScanDone = true; tokenInitialScan = false
        }
        do {
            analytics = try await tokens.scanAnalytics { [weak self] report in
                await self?.acceptAnalytics(report)
            }
            tokenReport = await tokens.ledger()
            tokenScanDone = true
            await updateProjections()
        } catch is CancellationError {
        } catch { tokenScanError = display(error); tokenScanDone = true }
    }
    func toggleFollow(_ session: Conversation) {
        guard session.kind == .code, session.cliSessionID != nil else { return }
        if follows(session.id) { library.follows.removeAll { $0.matches(session) } }
        else {
            library.follows.append(FollowRule(conversationID: session.id, sessionID: session.sessionID,
                                              transferMode: transferMode(session)))
        }
        persist()
    }
    func setPendingTransferMode(_ mode: SessionTransferMode, sessionID: String? = nil) {
        guard !working, var operation = pending else { return }
        for session in operation.sessions where sessionID == nil || session.id == sessionID {
            operation.plan.transferModes[session.id] = mode
        }
        pending = operation
    }
    func prepare(_ kind: OperationKind, target: Account, sessions explicitSessions: [Conversation]? = nil) async {
        if kind == .switchAccount, library.accounts.first(where: { $0.id == target.id })?.loginInvalidAt != nil {
            message = L10n.tr("The login of {0} is no longer valid; sign in to it in Claude once more.", L10n.argument(identity(target)))
            showAddAccount = true
            return
        }
        let following = SessionLibrary.followedSessions(inventory?.conversations ?? [], rules: library.follows,
            activeAccountID: activeID, targetAccountID: target.id)
        let candidates = explicitSessions ?? (kind == .switchAccount ? following : [])
        var seen = Set<String>()
        let transfers = candidates.sorted {
            if ($0.accountID == activeID) != ($1.accountID == activeID) { return $0.accountID == activeID }
            return $0.modifiedAt > $1.modifiedAt
        }.filter { $0.accountID != target.id && !$0.archived && seen.insert($0.sessionID).inserted }
        let modes = Dictionary(uniqueKeysWithValues: transfers.map { ($0.id, transferMode($0)) })
        message = nil
        do {
            var plan: OperationPlan
            if demo {
                plan = OperationPlan(kind: kind, sourceAccountID: activeID, targetAccountID: target.id, configDigest: "demo",
                    steps: kind == .switchAccount
                        ? [L10n.tr("Quit Claude normally"), L10n.tr("Replace the target login state"), L10n.tr("Bring followed conversations along, replacing older versions in the target account"), L10n.tr("Reopen Claude")]
                        : [L10n.tr("Quit Claude normally"), L10n.tr("Write the conversations to the target account, replacing older versions"), L10n.tr("Remove or keep the conversations in the original account as selected"), L10n.tr("Reopen Claude")],
                    conversationIDs: transfers.map(\.id), warnings: [L10n.tr("This is an interface demo. No accounts will be changed.")])
                plan.transferModes = modes; plan.targetOrganizationID = target.organizationID
            } else { plan = try await engine.prepare(kind: kind, target: target, sessions: transfers, transferModes: modes) }
            pending = PendingOperation(plan: plan, target: target, sessions: transfers)
        } catch { message = display(error) }
    }
    func executePending() async {
        guard canExecute, let operation = pending else { return }
        working = true
        var signedIn: String?
        do {
            message = try await engine.execute(operation.plan, confirmedPlanID: operation.id,
                                               target: operation.target, sessions: operation.sessions)
            // Follow the logical session after either transfer. A move changes its index owner;
            // the stable session ID also survives a restart between commit and this preference save.
            for session in operation.sessions {
                transferChoices[session.sessionID] = operation.plan.transferMode(for: session.id)
                for index in library.follows.indices where library.follows[index].matches(session) {
                    library.follows[index].sessionID = session.sessionID
                    library.follows[index].transferMode = operation.plan.transferMode(for: session.id)
                    if let org = operation.target.organizationID {
                        library.follows[index].conversationID = operation.target.id + "/" + org + "/" + session.kind.rawValue + "/" + session.sessionID
                    }
                }
            }
            if operation.plan.kind == .capture {
                var updated = knownAccounts
                if let i = updated.firstIndex(where: { $0.id == operation.target.id }) {
                    updated[i].lastSavedAt = Date(); updated[i].hasSnapshot = true
                }
                library.accounts = updated
            }
            if [.capture, .switchAccount].contains(operation.plan.kind) { signedIn = operation.target.id }
            persist()
        } catch { message = display(error) }
        pending = nil; working = false
        // Claude comes to the front signed in to the new account; a lingering workbench would show the old state.
        if operation.plan.kind == .switchAccount, signedIn != nil { WorkbenchLifecycle.shared.closeWorkbench() }
        await refresh()
        if let signedIn {
            Task { await refreshLive(trigger: .accountChanged(signedIn)) }
            if operation.plan.kind == .switchAccount { watchSwitchedLogin(signedIn) }
        }
    }

    @Published var awaitingNewLogin = false
    private var loginWatch: Task<Void, Never>?
    /// Accounts whose saved login is gone from the vault but that Switch still holds a copy of.
    @Published var recoverableLogins: [String] = []
    func restoreLogin(_ accountID: String) async {
        guard !demo, !working else { return }
        working = true
        do {
            try await engine.restoreLogin(accountID: accountID)
            message = L10n.tr("Restored the saved login of {0}.", L10n.argument(identity(id: accountID)))
        } catch { message = display(error) }
        working = false
        await refresh()
    }
    /// Deletes the copies a recoverable login still has, like removing a saved account.
    func discardRecoverable(_ accountID: String) async {
        await remove(knownAccounts.first { $0.id == accountID } ?? Account(id: accountID))
    }
    /// Adds an account without signing out anywhere: the signed-in login moves into Switch's vault,
    /// Claude reopens at its sign-in screen, and whatever account is signed in next is saved.
    func addAccount() async {
        guard canExecute else { return }
        message = nil
        guard let activeID, let account = knownAccounts.first(where: { $0.id == activeID }) else {
            // Claude already shows its sign-in screen; there is no login to move out.
            showAddAccount = false
            if let app = environment.application {
                _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            }
            watchForNewLogin()
            return
        }
        working = true
        do {
            let plan = try await engine.prepare(kind: .signOut, target: account)
            message = try await engine.execute(plan, confirmedPlanID: plan.id, target: account, sessions: [])
            showAddAccount = false; working = false
            WorkbenchLifecycle.shared.closeWorkbench()
            await refresh()
            watchForNewLogin()
            return
        } catch { message = display(error) }
        working = false
        await refresh()
    }
    /// Polls quickly while Claude shows its sign-in screen, so the new login is saved within seconds.
    private func watchForNewLogin() {
        awaitingNewLogin = true
        let started = Date()
        loginWatch?.cancel()
        loginWatch = Task { [weak self] in
            for _ in 0..<300 {
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                guard let self else { return }
                await self.refresh()
                if let account = self.activeAccount, (account.lastSavedAt ?? .distantPast) > started {
                    self.awaitingNewLogin = false
                    self.message = L10n.tr("Saved {0}. You can now switch with one click.", L10n.argument(self.identity(account)))
                    return
                }
            }
            self?.awaitingNewLogin = false
        }
    }
    /// Claude signs out within seconds when the server rejects a restored login; catch that while it happens.
    private func watchSwitchedLogin(_ accountID: String) {
        loginWatch?.cancel()
        loginWatch = Task { [weak self] in
            for _ in 0..<12 {
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                guard let self else { return }
                await self.refresh()
                if let account = self.library.accounts.first(where: { $0.id == accountID }), account.loginInvalidAt != nil {
                    self.message = L10n.tr("The server voided the saved login of {0}; Claude shows its sign-in screen. Sign in to this account in Claude again and it will be saved.",
                                           L10n.argument(self.identity(account)))
                    self.watchForNewLogin()
                    return
                }
            }
        }
    }
    func recover(_ id: String) async {
        guard canExecute else { return }
        working = true
        do { try await engine.recover(transactionID: id); message = L10n.tr("The unfinished transaction was recovered. Open Claude manually.") }
        catch { message = display(error) }
        working = false; await refresh()
    }
    private func display(_ error: Error) -> String {
        (error as? SwitchError)?.localizedDescription ?? L10n.tr("Could not read: {0}", L10n.argument(error.localizedDescription))
    }
}
