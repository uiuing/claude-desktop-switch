import AppKit
import Foundation
import Observation
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

/// Views redraw only for the properties they read, so a statistics scan does not redraw the menu bar.
@MainActor
@Observable
final class AppState {
    /// The app's one instance. A second one would run its own refresh, save and recovery loop.
    static let shared = AppState()
    var page: NavigationPage = .accounts
    var library = LibraryState()
    var inventory: LocalInventory?
    var tokenDays = 0
    var analytics = UsageAnalytics()
    var tokenScanError: String?
    var tokenInitialScan = true
    var refreshing = false { didSet { updateQuotaRefreshPause() } }
    var usageRefreshingAccountID: String? { didSet { updateQuotaRefreshPause() } }
    var usageErrors: [String: String] = [:]
    var quotaAccessRequired = false
    var authorizingQuotaAccess = false
    /// A manual read that came within the per-login back-off; its notice counts down and clears itself.
    private(set) var usageCooldowns: [String: UsageCoolingDown] = [:]
    /// Recovery guidance stays visible until a successful read replaces it.
    var usageNotices: [String: String] = [:]
    var scanningTokens = false
    var working = false { didSet {
        updateQuotaRefreshPause()
        if working { Task { await usageClient.cancelCurrentRead() } }
    } }
    var message: String?
    var pending: PendingOperation?
    var search = ""
    var selectedSessionIDs = Set<String>()
    var sessionFilter: SessionKind?
    var selectedAccountID: String?
    var showSessionInspector = true
    var showAddAccount = false
    var showQuickFind = false
    var recoveryIDs: [String] = []
    var tokenScanDone = false
    var savingLogin = false
    var loginSaveError: String?
    @ObservationIgnored private var loginSaveRecovery = LoginSaveRetry()
    @ObservationIgnored private var loginSaveRetry: Task<Void, Never>?
    let demo: Bool
    let startupAccess: StartupAccess
    let environment = MacEnvironment()
    private let store: LibraryStore
    private let reader: LocalReader
    private let sessionActivity: SessionActivityReader
    private let tokens: TokenScanner
    private let vault: CredentialVault
    private let engine: SwitchEngine
    private let usageClient: ActiveUsageClient
    @ObservationIgnored private var started = false
    private var libraryReadable = true
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var credentialObserver: DesktopUsageObserver?
    @ObservationIgnored private var observedLoginSignature: String?
    @ObservationIgnored private var recoveryAccounts = Set<String>()
    @ObservationIgnored private var lifecycleChecks: [String: Date] = [:]
    @ObservationIgnored private var resetChecks: [String: Date] = [:]
    @ObservationIgnored private var profileLookups = Set<String>()
    @ObservationIgnored private var quotaSchedule = QuotaRefreshSchedule()
    @ObservationIgnored private var networkAvailable = false
    @ObservationIgnored private var desktopAwake = true
    @ObservationIgnored private var automaticReadToken: UUID?
    @ObservationIgnored private var preparingManualQuota = false
    @ObservationIgnored private lazy var quotaRefreshQueue = QuotaRefreshQueue { [weak self] request in
        await self?.refreshLive(accountID: request.accountID, automatic: request)
    }
    private var transferChoices: [String: SessionTransferMode] = [:]

    init(demo: Bool = ProcessInfo.processInfo.arguments.contains("--demo"), startupAccess: StartupAccess? = nil) {
        self.demo = demo
        self.startupAccess = startupAccess ?? StartupAccess(ready: demo)
        let env = MacEnvironment()
        store = LibraryStore(root: env.root)
        reader = LocalReader(desktop: env.desktop, codeConfig: env.codeConfig, projects: env.projects)
        sessionActivity = SessionActivityReader(desktop: env.desktop, projects: env.projects)
        tokens = TokenScanner(projects: env.projects, cacheURL: env.root.appendingPathComponent("usage-cache.json"))
        let vault = CredentialVault(root: env.root.appendingPathComponent("vault"))
        self.vault = vault
        engine = SwitchEngine(environment: env, vault: vault)
        usageClient = ActiveUsageClient(environment: env, vault: vault)
        if demo {
            let data = DemoData.make()
            library = data.library; inventory = data.inventory; analytics = data.analytics
            tokenScanDone = true
        }
        Task { [weak self] in await self?.start() }
    }
    var activeID: String? { inventory?.activeAccountID }
    /// Accounts saved in Switch. Claude's local data only decides which of them is signed in.
    var accounts: [Account] { knownAccounts.filter(\.hasSnapshot) }
    /// The Claude Desktop login is known but Switch has not saved it (yet).
    var activeUnsaved: Bool { activeID != nil && activeAccount == nil }
    /// Claude shows its sign-in screen, whether Switch moved the login out or the server rejected it.
    var claudeSignedOut: Bool { !demo && inventory?.signedIn == false }
    /// Every account Claude Desktop has left on this Mac. Only used to attribute sessions.
    var knownAccounts: [Account] {
        var merged = Dictionary(library.accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for discovered in inventory?.accounts ?? [] {
            if var stored = merged[discovered.id] {
                stored.email = discovered.email ?? stored.email
                if let organization = discovered.organizationID {
                    if stored.organizationVerifiedAt == nil { stored.setOrganization(organization) }
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
    var canExecute: Bool { startupAccess.isReady && BuildAccess.allowsClaudeWrites && !demo && !working && libraryReadable }
    var currentUsage: UsageSnapshot? { activeID.flatMap { library.usage[$0] } }
    func quotaRows(for accountID: String, now: Date = Date()) -> [QuotaReadout] {
        AccountQuotaPresentation.rows(accountID: accountID, snapshot: library.usage[accountID], active: accountID == activeID,
                                      now: now, freshFor: quotaFreshness(for: accountID, now: now))
    }
    private func quotaFreshness(for accountID: String, now: Date) -> TimeInterval {
        max(600, quotaSchedule.interval(for: accountID, current: activeID, now: now) + 60)
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
                active: accountID == activeID, now: now, freshFor: quotaFreshness(for: accountID, now: now))
        }
    }
    private func acceptUsage(_ incoming: UsageSnapshot) {
        guard let snapshot = incoming.onlineOnly() else { return }
        library.usage[snapshot.accountID] = snapshot
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
        guard !demo else { return }
        await startupAccess.check(using: { try await self.usageClient.authorizeQuotaAccess(allowPrompt: $0) },
                                  start: { await self.startAuthorizedServices() })
    }
    func authorizeStartupAccess() async {
        guard !demo else { return }
        await startupAccess.authorize(using: { try await self.usageClient.authorizeQuotaAccess(allowPrompt: $0) },
                                      start: { await self.startAuthorizedServices() })
    }
    private func startAuthorizedServices() async {
        guard startupAccess.isReady else { return }
        guard !started else { return }; started = true
        guard !demo else { return }
        do { library = try await store.load() }
        catch { libraryReadable = false; message = L10n.tr("Could not read the Switch library. Settings changed in this session will not be saved.") }
        sampleDesktopActivity()
        if quotaSchedule.activity.running { Task(priority: .utility) { [weak self] in await self?.scanTokens() } }
        do { try await engine.purgeMovedAsideLogins() } catch { message = display(error) }
        try? await engine.pruneTransactions()
        if !(await refresh()) { watchForNewLogin() }
        requestCurrentQuotaIfStale()
        credentialObserver = DesktopUsageObserver(directory: environment.desktop) { [weak self] event in
            Task { @MainActor [weak self] in await self?.observeDesktop(event) }
        }
        polling = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                guard let self else { return }
                self.sampleDesktopActivity()
                guard self.quotaSchedule.activity.running, self.desktopAwake else { continue }
                await self.refresh()
                await self.sampleSessionActivity()
                await self.recoverQuotaAccessSilently()
                self.scheduleQuotaReads()
                if self.usageOnScreen || Date().timeIntervalSince(self.lastTokenScan) >= Self.backgroundScanInterval {
                    await self.scanTokens()
                }
            }
        }
    }
    /// Statistics only show on the Usage page; while it is off screen the cache is kept current far less often.
    private static let backgroundScanInterval: TimeInterval = 600
    @ObservationIgnored private var lastTokenScan = Date.distantPast
    private var usageOnScreen: Bool { page == .usage && WorkbenchLifecycle.shared.workbenchOnScreen }
    /// Opening the Usage page catches up at once instead of waiting for the next scan.
    func scanTokensIfStale() async {
        guard Date().timeIntervalSince(lastTokenScan) >= 60 else { return }
        await scanTokens()
    }
    @discardableResult
    func refresh(triggerQuotaEvents: Bool = true) async -> Bool {
        guard startupAccess.isReady, !refreshing, !working else { return false }
        if demo { return false }
        refreshing = true; defer { refreshing = false }
        var scanned = false
        do {
            let verified = Dictionary(library.accounts.compactMap { account in
                account.organizationVerifiedAt == nil ? nil : account.organizationID.map { (account.id, $0) }
            }, uniquingKeysWith: { first, _ in first })
            let result = try await reader.scan(verifiedOrganizations: verified)
            scanned = true
            var changed = false
            inventory = result
            selectedSessionIDs.formIntersection(unarchivedSessions.map(\.id))
            if triggerQuotaEvents, let id = result.activeAccountID { quotaRefreshQueue.observedAccount(id) }
            if triggerQuotaEvents, let id = result.activeAccountID, let signature = try? environment.credentialDigest() {
                quotaRefreshQueue.observedCredential(accountID: id, signature: signature)
            }
            let now = Date()
            if triggerQuotaEvents, let id = result.activeAccountID, let snapshot = library.usage[id],
               let reset = snapshot.windows.compactMap(\.resetsAt).filter({ $0 <= now }).max(), resetChecks[id] != reset {
                resetChecks[id] = reset
                quotaRefreshQueue.enqueueCurrent(id, reason: .reset)
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
            // Cookie absence is local evidence, not proof that a saved login was revoked by the server.
            if let id = result.lastKnownAccountID, let index = updated.firstIndex(where: { $0.id == id }) {
                if result.signedIn == false {
                    usageNotices[id] = L10n.tr("Verify the login in Claude. Switch will resume when updated credentials are available.")
                    recoveryAccounts.insert(id)
                }
                if result.signedIn == true, updated[index].snapshotFingerprint != (try? await engine.currentLoginFingerprint()) {
                    updated[index].loginInvalidAt = nil
                }
            }
            for account in updated where library.accounts.first(where: { $0.id == account.id })?.plan != account.plan {
                library.usage[account.id] = nil; resetChecks[account.id] = nil
            }
            if library.accounts != updated { library.accounts = updated; changed = true }
            recoveryIDs = try await engine.pendingRecovery()
            recoverableLogins = await engine.recoverableLogins()
                .filter { id in !updated.contains { $0.id == id && $0.hasSnapshot } }.sorted()
            if changed { persist() }
        } catch is CancellationError {
        } catch { message = display(error) }
        await saveCurrentLogin(triggerQuotaEvents: triggerQuotaEvents)
        synchronizeQuotaSchedule()
        if scanned, switchLoginWatch == nil, claudeSignedOut || activeUnsaved { watchForNewLogin() }
        return scanned
    }
    /// Keeps the signed-in account's saved login current. Only Switch's own vault is written.
    /// `retry` is the user asking again; a failed save is otherwise only retried on its own schedule.
    func saveCurrentLogin(retry: Bool = false, triggerQuotaEvents: Bool = true) async {
        guard startupAccess.isReady, !demo, libraryReadable, !savingLogin, !working, let activeID else { return }
        guard let fingerprint = try? await engine.currentLoginFingerprint() else { return }
        let stored = knownAccounts.first { $0.id == activeID }
        if stored?.hasSnapshot == true && stored?.snapshotFingerprint == fingerprint { loginSaveError = nil; return }
        guard loginSaveRecovery.shouldAttempt(fingerprint, manual: retry, now: Date()) else { return }
        savingLogin = true; defer { savingLogin = false }
        do {
            let saved = try await engine.saveCurrentLogin()
            var all = knownAccounts
            guard let index = all.firstIndex(where: { $0.id == saved.accountID }) else { return }
            let added = !all[index].hasSnapshot
            all[index].hasSnapshot = true; all[index].lastSavedAt = Date(); all[index].snapshotFingerprint = saved.fingerprint
            all[index].loginInvalidAt = nil
            library.accounts = all; loginSaveError = nil; loginSaveRecovery.reset(); loginSaveRetry?.cancel()
            persist()
            if added && triggerQuotaEvents { quotaRefreshQueue.enqueue(saved.accountID) }
        } catch {
            let delay = loginSaveRecovery.failed(transient: Self.retriesLoginSave(after: error), now: Date())
            loginSaveError = loginSaveRecovery.showError ? loginSaveMessage(error) : nil
            if let delay {
                loginSaveRetry?.cancel()
                loginSaveRetry = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard !Task.isCancelled, let self else { return }
                    self.sampleDesktopActivity()
                    guard self.desktopAwake, self.quotaSchedule.activity.running else { return }
                    await self.saveCurrentLogin(triggerQuotaEvents: triggerQuotaEvents)
                }
            }
        }
    }
    func retryLoginSave() async {
        guard startupAccess.isReady, !demo, !working else { return }
        loginSaveRecovery.reset(); loginSaveRetry?.cancel(); loginSaveError = nil
        watchForNewLogin()
        await refresh()
    }
    private static func retriesLoginSave(after error: Error) -> Bool {
        guard let error = error as? SwitchError else { return true }
        switch error {
        case .changed, .busy, .missing: return true
        case .blocked, .malformed, .unsafePath: return false
        }
    }
    private func loginSaveMessage(_ error: Error) -> String {
        if case .changed? = error as? SwitchError {
            return L10n.tr("Claude kept writing its data while the login was being copied. Try again in a moment.")
        }
        return display(error)
    }
    func canRemove(_ account: Account) -> Bool { startupAccess.isReady && account.id != activeID && usageRefreshingAccountID != account.id && !working }
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
        quotaRefreshQueue.discard(account.id)
        synchronizeQuotaSchedule()
        for index in library.follows.indices { library.follows[index].targetAccountIDs.removeAll { $0 == account.id } }
        recoverableLogins.removeAll { $0 == account.id }
        persist()
    }
    func persist() {
        guard startupAccess.isReady, !demo, libraryReadable else { return }
        let state = library
        Task { do { try await store.save(state) } catch { message = L10n.tr("Could not save settings.") } }
    }
    private func updateQuotaRefreshPause() {
        quotaRefreshQueue.isPaused = !startupAccess.isReady || demo || working || refreshing || preparingManualQuota || usageRefreshingAccountID != nil ||
            !library.preferences.quotaRefresh.enabled || !quotaSchedule.activity.permitsAutomaticReads
    }
    private func synchronizeQuotaSchedule() {
        quotaSchedule.preferences = library.preferences.quotaRefresh.normalized
        quotaSchedule.synchronize(accounts: accounts.filter { $0.loginInvalidAt == nil }, snapshots: library.usage, now: Date())
        quotaSchedule.selectCurrent(activeID, now: Date())
        if quotaSchedule.accountsAwaitingAccess.isEmpty { quotaAccessRequired = false }
    }
    func setQuotaRefreshPreferences(_ preferences: QuotaRefreshPreferences) {
        library.preferences.quotaRefresh = preferences.normalized
        synchronizeQuotaSchedule()
        sampleDesktopActivity()
        quotaRefreshQueue.discardPeriodic()
        scheduleQuotaReads()
        persist()
    }
    private func sampleDesktopActivity() {
        guard !demo else { return }
        quotaSchedule.activity = DesktopUsageObserver.activity(online: networkAvailable, awake: desktopAwake)
        updateQuotaRefreshPause()
        if !quotaSchedule.activity.permitsAutomaticReads || !library.preferences.quotaRefresh.enabled, let token = automaticReadToken {
            Task {
                guard automaticReadToken == token else { return }
                await usageClient.cancelCurrentRead()
            }
        }
    }
    private func sampleSessionActivity() async {
        guard library.preferences.quotaRefresh.enabled, library.preferences.quotaRefresh.adaptive,
              quotaSchedule.activity.running, desktopAwake, !working, let inventory, let id = activeID, let org = activeAccount?.organizationID else { return }
        let observation = await sessionActivity.scan(accountID: id, organizationID: org,
                                                     accounts: knownAccounts, conversations: inventory.conversations)
        guard activeID == id, !working else { return }
        quotaSchedule.observeTaskChanges(accountID: id, changed: observation.changed, complete: observation.complete && inventory.warnings.isEmpty, at: observation.observedAt)
    }
    private func scheduleQuotaReads() {
        guard !demo, !working else { return }
        synchronizeQuotaSchedule()
        for id in quotaSchedule.dueAccounts(current: activeID, now: Date()) { quotaRefreshQueue.enqueuePeriodic(id) }
    }
    private func observeDesktop(_ event: DesktopUsageObserver.Event) async {
        guard !demo else { return }
        switch event {
        case .sleep: desktopAwake = false; clearQuotaAccess()
        case .wake: desktopAwake = true
        case .networkRestored: networkAvailable = true
        case .networkUnavailable: networkAvailable = false
        default: break
        }
        sampleDesktopActivity()
        if event == .wake || event == .launched { loginDiscovery?.resume() }
        guard !working, quotaSchedule.activity.running, desktopAwake else { return }
        if event != .networkUnavailable {
            let signature = await loginSignature()
            if signature != observedLoginSignature || event == .launched {
                if await refresh() { observedLoginSignature = signature }
                else if switchLoginWatch == nil { watchForNewLogin() }
            }
            if event != .credentials { requestCurrentQuotaIfStale() }
        }
        await recoverQuotaAccessSilently()
        scheduleQuotaReads()
    }
    private func requestCurrentQuotaIfStale() {
        guard let id = activeID, !demo, !working, library.preferences.quotaRefresh.enabled, quotaSchedule.activity.permitsAutomaticReads, !quotaSchedule.isBlocked(id),
              Date().timeIntervalSince(lifecycleChecks[id] ?? .distantPast) >= 60 else { return }
        let snapshot = library.usage[id]
        if recoveryAccounts.contains(id) || snapshot == nil || Date().timeIntervalSince(snapshot!.observedAt) >= quotaSchedule.interval(for: id, current: activeID, now: Date()) {
            lifecycleChecks[id] = Date()
            quotaRefreshQueue.enqueueCurrent(id, reason: .lifecycle)
        }
    }
    /// Toolbar and keyboard refresh update local inventory and statistics only.
    func refreshLocalRecords() async {
        guard startupAccess.isReady else { return }
        await refresh(triggerQuotaEvents: false)
        if page == .usage { await scanTokens() }
    }
    func clearQuotaAccess() { usageClient.clearQuotaAccess() }
    /// One explicit approval retries all accounts held for the same shared permission.
    func authorizeQuotaAccess() async {
        guard startupAccess.isReady, !demo, !working, !authorizingQuotaAccess, usageRefreshingAccountID == nil else { return }
        authorizingQuotaAccess = true; preparingManualQuota = true; updateQuotaRefreshPause()
        defer { authorizingQuotaAccess = false; preparingManualQuota = false; updateQuotaRefreshPause() }
        do {
            try await usageClient.authorizeQuotaAccess(allowPrompt: true)
            quotaAccessRequired = false
            let ids = quotaSchedule.resumeAfterAccess().sorted { a, b in
                if a == activeID { return true }; if b == activeID { return false }; return a < b
            }
            for (index, id) in ids.enumerated() {
                if index > 0 {
                    do { try await Task.sleep(nanoseconds: 15_000_000_000) }
                    catch { for pending in ids[index...] { quotaRefreshQueue.enqueueRecovery(pending) }; return }
                }
                sampleDesktopActivity()
                guard !working, quotaSchedule.activity.permitsAutomaticReads else {
                    for pending in ids[index...] { quotaRefreshQueue.enqueueRecovery(pending) }
                    return
                }
                _ = await refreshLive(accountID: id, allowKeychainPrompt: false)
                if quotaAccessRequired {
                    for pending in ids.dropFirst(index + 1) { quotaSchedule.suspend(pending, awaitingAccess: true) }
                    return
                }
            }
        } catch { quotaAccessRequired = true }
    }
    private func resumeQuotaAfterAccess() {
        guard usageClient.quotaAccessAvailable else { return }
        quotaAccessRequired = false
        for id in quotaSchedule.resumeAfterAccess() { quotaRefreshQueue.enqueueRecovery(id) }
    }
    private func recoverQuotaAccessSilently() async {
        guard quotaAccessRequired, !authorizingQuotaAccess, !working, usageRefreshingAccountID == nil,
              library.preferences.quotaRefresh.enabled, quotaSchedule.activity.permitsAutomaticReads else { return }
        try? await usageClient.authorizeQuotaAccess(allowPrompt: false)
        resumeQuotaAfterAccess()
    }
    /// Rescans local identity and reads the selected account without switching to it.
    func refreshNow(accountID: String) async {
        guard startupAccess.isReady, !authorizingQuotaAccess else { return }
        if quotaAccessRequired {
            let waiting = quotaSchedule.accountsAwaitingAccess.contains(accountID)
            await authorizeQuotaAccess()
            if waiting || quotaAccessRequired { return }
        }
        _ = await refreshLive(accountID: accountID)
    }
    /// Returns a retry time for queued automatic reads; manual reads report their result immediately.
    private func refreshLive(accountID: String, automatic: QuotaRefreshQueue.Request? = nil, allowKeychainPrompt: Bool = true) async -> Date? {
        guard startupAccess.isReady, !demo else { return nil }
        let manual = automatic == nil
        if !manual {
            sampleDesktopActivity()
            guard library.preferences.quotaRefresh.enabled, quotaSchedule.activity.permitsAutomaticReads else { return Date().addingTimeInterval(60) }
            if automatic?.reason == .periodic, !quotaSchedule.dueAccounts(current: activeID, now: Date()).contains(accountID) { return nil }
            if automatic?.reason == .credentialsChanged || automatic?.reason == .accountChanged {
                quotaSchedule.credentialsChanged(accountID)
            }
            guard !quotaSchedule.isBlocked(accountID) else { return nil }
        }
        guard !working, usageRefreshingAccountID == nil else { return manual ? nil : Date().addingTimeInterval(1) }
        usageRefreshingAccountID = accountID
        automaticReadToken = manual ? nil : UUID()
        var succeeded = false
        defer {
            automaticReadToken = nil
            if manual { quotaRefreshQueue.completedManualRead(accountID: accountID, succeeded: succeeded) }
            resumeQuotaAfterAccess()
            usageRefreshingAccountID = nil
        }
        if manual {
            dismissUsageError(accountID); usageNotices[accountID] = nil
            await refresh(triggerQuotaEvents: false)
        }
        guard accounts.contains(where: { $0.id == accountID && $0.loginInvalidAt == nil }) else { return nil }
        synchronizeQuotaSchedule()
        quotaSchedule.began(accountID, at: Date())
        let saved = activeID != accountID && (manual || inventory?.lastKnownAccountID != accountID)
        // A switched-in login is renewed by Claude itself after it starts; wait locally rather than asking early.
        let deadline = automatic?.readinessDeadline ?? .distantPast
        do {
            guard !working, saved || activeID == accountID else { throw UsageNotReady(message: SwitchError.changed.localizedDescription) }
            let snapshot: UsageSnapshot
            do {
                if saved { snapshot = try await usageClient.fetchSaved(accountID: accountID, allowKeychainPrompt: manual && allowKeychainPrompt) }
                else { snapshot = try await usageClient.fetchCurrent(accountID: accountID, allowKeychainPrompt: manual && allowKeychainPrompt,
                                                                    onlyIfTokenChanged: automatic?.reason == .credentialsChanged) }
            } catch {
                await acceptVerifiedProfile(accountID: accountID, saved: saved)
                throw error
            }
            guard !working, saved || activeID == snapshot.accountID else { throw SwitchError.changed }
            guard library.accounts.contains(where: { $0.id == accountID && $0.hasSnapshot }) else { return nil }
            if !manual {
                sampleDesktopActivity()
                guard library.preferences.quotaRefresh.enabled, quotaSchedule.activity.permitsAutomaticReads else { return Date().addingTimeInterval(60) }
            }
            await acceptVerifiedProfile(accountID: accountID, saved: saved)
            acceptUsage(snapshot)
            quotaSchedule.succeeded(snapshot)
            succeeded = true
            recoveryAccounts.remove(accountID)
            dismissUsageError(accountID); usageNotices[accountID] = nil
            persist()
            return nil
        } catch is UsageUnchanged {
            return nil
        } catch is CancellationError {
            return manual ? nil : Date().addingTimeInterval(60)
        } catch SwitchError.busy {
            return manual ? nil : Date().addingTimeInterval(1)
        } catch SwitchError.changed {
            recoveryAccounts.insert(accountID)
            dismissUsageError(accountID)
            usageNotices[accountID] = L10n.tr("Waiting for Claude to publish its login credentials.")
            if Date() >= deadline { quotaSchedule.suspend(accountID) }
            return Date() < deadline ? Date().addingTimeInterval(10) : nil
        } catch let notReady as UsageNotReady {
            recoveryAccounts.insert(accountID)
            dismissUsageError(accountID)
            usageNotices[accountID] = notReady.message
            if Date() >= deadline { quotaSchedule.suspend(accountID) }
            return Date() < deadline ? Date().addingTimeInterval(10) : nil
        } catch let cooling as UsageCoolingDown {
            showCooldown(cooling, for: accountID)
            quotaSchedule.deferRead(accountID, until: cooling.until)
            return manual ? nil : cooling.until
        } catch let failure as UsageFailure {
            usageCooldowns[accountID] = nil
            if failure == .keychain {
                quotaSchedule.suspend(accountID, awaitingAccess: true)
                quotaAccessRequired = true
                usageErrors[accountID] = nil; usageNotices[accountID] = nil
                return nil
            }
            if !failure.isTransient { quotaSchedule.suspend(accountID) }
            if failure.waitsForCredentials {
                recoveryAccounts.insert(accountID)
                usageNotices[accountID] = failure.localizedDescription
                usageErrors[accountID] = nil
            } else {
                usageNotices[accountID] = nil
                usageErrors[accountID] = failure.localizedDescription
                if failure.isTransient { recoveryAccounts.insert(accountID) }
                else { recoveryAccounts.remove(accountID) }
            }
            return failure.isTransient && Date() < deadline ? Date().addingTimeInterval(60) : nil
        } catch {
            quotaSchedule.suspend(accountID)
            usageCooldowns[accountID] = nil
            usageErrors[accountID] = display(error)
            return nil
        }
    }
    private func acceptVerifiedProfile(accountID: String, saved: Bool) async {
        let identity = await usageClient.identity(), verified = await usageClient.takeVerifiedPlan()
        guard !working, saved || activeID == accountID, identity?.id == accountID,
              let index = library.accounts.firstIndex(where: { $0.id == accountID && $0.hasSnapshot }),
              let organization = identity?.organizationID else { return }
        let oldPlan = library.accounts[index].plan, oldOrganization = library.accounts[index].organizationID
        library.accounts[index].email = identity?.email ?? library.accounts[index].email
        library.accounts[index].confirmOrganization(organization, at: Date())
        if let verified, verified.accountID == accountID, verified.organizationID == organization {
            library.accounts[index].observePlan(verified.plan, organizationID: organization, at: verified.observedAt, verified: true)
        }
        if oldPlan != library.accounts[index].plan || oldOrganization != organization {
            library.usage[accountID] = nil; resetChecks[accountID] = nil
        }
        persist()
    }
    /// The problem with this account's last live read, while it still applies.
    func usageError(for accountID: String) -> String? {
        if let cooling = usageCooldowns[accountID], cooling.until > Date() { return cooling.errorDescription }
        return usageErrors[accountID]
    }
    func usageStatus(for accountID: String) -> String? {
        if usageRefreshingAccountID == accountID { return L10n.tr("Reading quota…") }
        return usageError(for: accountID) ?? usageNotices[accountID]
    }
    func dismissUsageError(_ accountID: String) {
        usageErrors[accountID] = nil; usageCooldowns[accountID] = nil
    }
    private func showCooldown(_ cooling: UsageCoolingDown, for accountID: String) {
        usageCooldowns[accountID] = cooling
    }
    private func acceptAnalytics(_ report: UsageAnalytics) {
        analytics = report; tokenScanDone = true
    }
    func scanTokens() async {
        guard startupAccess.isReady, !demo, !scanningTokens else { return }
        lastTokenScan = Date()
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
            tokenScanDone = true
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
        if let signedIn {
            if operation.plan.kind == .switchAccount {
                quotaRefreshQueue.switched(from: operation.plan.sourceAccountID, to: signedIn)
            } else { quotaRefreshQueue.enqueue(signedIn) }
        }
        pending = nil; working = false
        // Claude comes to the front signed in to the new account; a lingering workbench would show the old state.
        if operation.plan.kind == .switchAccount, signedIn != nil { WorkbenchLifecycle.shared.closeWorkbench() }
        await refresh()
        if let signedIn {
            if operation.plan.kind == .switchAccount { watchSwitchedLogin(signedIn) }
        }
    }

    var awaitingNewLogin = false
    @ObservationIgnored private var loginWatch: Task<Void, Never>?
    @ObservationIgnored private var loginDiscovery: LoginDiscovery?
    @ObservationIgnored private var switchLoginWatch: Task<Void, Never>?
    /// Accounts whose saved login is gone from the vault but that Switch still holds a copy of.
    var recoverableLogins: [String] = []
    func restoreLogin(_ accountID: String) async {
        guard startupAccess.isReady, !demo, !working else { return }
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
    /// Scan immediately, observe publications each second, and recheck unchanged state after transient races.
    private func watchForNewLogin() {
        guard !demo, startupAccess.isReady, loginWatch == nil else { return }
        switchLoginWatch?.cancel(); switchLoginWatch = nil
        awaitingNewLogin = true
        let discovery = LoginDiscovery(paused: { [weak self] in
            guard let self else { return true }
            return self.working || self.refreshing || !self.desktopAwake || !self.quotaSchedule.activity.running
        }, signature: { [weak self] in
            await self?.loginSignature() ?? ""
        }, scan: { [weak self] in
            guard let self, await self.refresh() else { return .retry }
            guard self.inventory?.signedIn == true, let account = self.activeAccount,
                  let fingerprint = try? await self.engine.currentLoginFingerprint(),
                  !self.working, self.activeID == account.id, account.snapshotFingerprint == fingerprint else { return .pending }
            return .saved
        })
        loginDiscovery = discovery
        loginWatch = Task { [weak self] in
            while !Task.isCancelled {
                await discovery.poll()
                guard let self, self.loginDiscovery === discovery else { return }
                if discovery.completed, let account = self.activeAccount {
                    self.awaitingNewLogin = false; self.loginDiscovery = nil; self.loginWatch = nil
                    self.message = L10n.tr("Saved {0}. You can now switch with one click.", L10n.argument(self.identity(account)))
                    return
                }
                do { try await Task.sleep(nanoseconds: UInt64(discovery.pollingInterval * 1_000_000_000)) } catch { return }
            }
        }
    }
    /// Metadata changes only trigger a scan; they never establish identity or prove that Claude signed in.
    private func loginSignature() async -> String {
        let environment = environment
        return await Task.detached(priority: .utility) {
            let stamps = LoginProbe.publicationSignature(desktop: environment.desktop)
            return digest((try? JSONEncoder().encode(stamps)) ?? Data())
        }.value
    }
    /// Rescans everything once the login changed. A rescan that cannot run yet is tried again on the next check.
    private func refreshOnLoginChange(since seen: inout String?) async {
        let current = await loginSignature()
        guard current != seen, !refreshing, !working else { return }
        if await refresh() { seen = current }
    }
    /// Observe startup changes without treating a temporarily absent cookie as server rejection.
    private func watchSwitchedLogin(_ accountID: String) {
        loginWatch?.cancel(); loginWatch = nil; loginDiscovery = nil; awaitingNewLogin = false
        switchLoginWatch?.cancel()
        switchLoginWatch = Task { [weak self] in
            var seen: String?
            for _ in 0..<12 {
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                guard let self else { return }
                await self.refreshOnLoginChange(since: &seen)
                if self.inventory?.signedIn == false {
                    self.usageNotices[accountID] = L10n.tr("Verify the login in Claude. Switch will resume when updated credentials are available.")
                    self.recoveryAccounts.insert(accountID)
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.switchLoginWatch = nil
            if self.claudeSignedOut || self.activeUnsaved { self.watchForNewLogin() }
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
