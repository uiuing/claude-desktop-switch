import Foundation
import SwitchCore
import SwitchStorage

private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
enum ClaudeCodeVersion {
    /// Newest Claude Code installed by Claude Desktop, else by the standalone installer.
    static func installed(_ environment: MacEnvironment) -> String? {
        for root in [environment.desktop.appendingPathComponent("claude-code"),
                     environment.home.appendingPathComponent(".local/share/claude/versions")] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            let versions = names.filter { $0.range(of: #"^\d+(\.\d+){1,3}$"#, options: .regularExpression) != nil }
            if let newest = versions.max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) { return newest }
        }
        return nil
    }
}
/// Read-only OAuth compatibility requests. Desktop remains the sole credential renewal owner.
public actor ActiveUsageClient: UsageProvider {
    static let spacing: TimeInterval = 60, rateLimitWait: TimeInterval = 300, longestWait: TimeInterval = 3600
    typealias Transport = (URLSession, URLRequest) async throws -> (Data, HTTPURLResponse)
    private let environment: MacEnvironment
    private let vault: CredentialVault
    private let transport: Transport
    private let now: () -> Date
    private var cooldowns: [String: Date] = [:]
    private var denied: [String: UsageFailure] = [:]
    private var legacyCooldowns: [String: Date] = [:]
    private var legacyDenied = Set<String>()
    private var failures: [String: Int] = [:]
    private var attemptedTokens: [String: String] = [:]
    private var inFlight = false
    private var sessionInFlight: URLSession?
    private var cancellationGeneration: UInt64 = 0
    private var storageFailed = false
    private var verifiedAccount: Account?
    private var verifiedPlan: (accountID: String, organizationID: String, plan: String?, observedAt: Date)?
    public init(environment: MacEnvironment, vault: CredentialVault? = nil) {
        self.init(environment: environment, vault: vault, transport: Self.send)
    }
    init(environment: MacEnvironment, vault: CredentialVault? = nil, transport: @escaping Transport, now: @escaping () -> Date = Date.init) {
        self.environment = environment; self.vault = vault ?? CredentialVault(root: environment.root.appendingPathComponent("vault"))
        self.transport = transport; self.now = now
    }
    public func identity() -> Account? { verifiedAccount }
    public nonisolated var quotaAccessAvailable: Bool { DesktopTokenReader.access.available }
    public nonisolated func clearQuotaAccess() { DesktopTokenReader.access.clear() }
    public func authorizeQuotaAccess(allowPrompt: Bool) async throws {
        guard !inFlight else { throw SwitchError.busy }
        inFlight = true; defer { inFlight = false }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    var key = try DesktopTokenReader.authorize(allowPrompt: allowPrompt)
                    key.resetBytes(in: 0..<key.count)
                })
            }
        }
    }
    public func takeVerifiedPlan() -> (accountID: String, organizationID: String, plan: String?, observedAt: Date)? {
        defer { verifiedPlan = nil }; return verifiedPlan
    }
    public func cancelCurrentRead() {
        cancellationGeneration &+= 1
        sessionInFlight?.invalidateAndCancel()
    }
    public func fetchCurrent(accountID: String) async throws -> UsageSnapshot {
        try await fetchCurrent(accountID: accountID, allowKeychainPrompt: false)
    }
    public func fetchCurrent(accountID: String, allowKeychainPrompt: Bool, onlyIfTokenChanged: Bool = false) async throws -> UsageSnapshot {
        let environment = environment
        return try await fetch(accountID: accountID, onlyIfTokenChanged: onlyIfTokenChanged, readToken: {
            guard try environment.currentAccount() == accountID, environment.signedIn() == true else {
                throw UsageNotReady(reason: .updating)
            }
            return try await Self.readOffThread {
                try DesktopTokenReader.read(environment: environment, expectedAccount: accountID, allowPrompt: allowKeychainPrompt)
            }
        }, validate: { token in
            guard try environment.currentAccount() == token.accountID, environment.signedIn() == true,
                  try environment.credentialDigest() == token.credentialDigest else { throw SwitchError.changed }
        })
    }
    public func fetchSaved(accountID: String, allowKeychainPrompt: Bool = false) async throws -> UsageSnapshot {
        let vault = vault
        do {
            return try await fetch(accountID: accountID, readToken: {
                let snapshot = try await vault.load(accountID: accountID)
                return try await Self.readOffThread {
                    try DesktopTokenReader.read(config: .object(snapshot.auth), expectedAccount: accountID, allowPrompt: allowKeychainPrompt)
                }
            }, validate: { token in
                let snapshot = try await vault.load(accountID: accountID)
                guard try IdentitySchema.fingerprint(.object(snapshot.auth)) == token.credentialDigest else { throw SwitchError.changed }
            })
        } catch is UsageNotReady {
            throw SwitchError.blocked(L10n.tr("The saved access token has expired. Switch to this account and let Claude update its login, then refresh again."))
        }
    }
    private static func readOffThread(_ read: @escaping () throws -> DesktopAccessToken) async throws -> DesktopAccessToken {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result(catching: read)) }
        }
    }
    func fetch(accountID: String, onlyIfTokenChanged: Bool = false, readToken: () async throws -> DesktopAccessToken,
               validate: (DesktopAccessToken) async throws -> Void) async throws -> UsageSnapshot {
        guard !inFlight else { throw SwitchError.busy }
        inFlight = true; defer { inFlight = false }
        let generation = cancellationGeneration
        verifiedPlan = nil; verifiedAccount = nil
        let token = try await readToken()
        try checkCancellation(generation)
        guard token.accountID == accountID else { throw SwitchError.changed }
        try await validate(token)
        try checkCancellation(generation)
        guard token.expiresAt > now().addingTimeInterval(60) else { throw UsageNotReady(reason: .expiring) }
        if onlyIfTokenChanged, attemptedTokens[accountID] == token.tokenDigest { throw UsageUnchanged() }
        guard let version = ClaudeCodeVersion.installed(environment) else {
            throw SwitchError.missing(L10n.tr("Claude Code was not found, so the quota compatibility request is unavailable."))
        }
        try reserve(token)
        attemptedTokens[accountID] = token.tokenDigest
        defer { do { try persist() } catch { storageFailed = true } }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10; configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        sessionInFlight = session
        defer { session.invalidateAndCancel(); sessionInFlight = nil }
        do {
            try checkCancellation(generation)
            let profileRequest = try DesktopUsageProtocol.request(path: "/api/oauth/profile", token: token.value, codeVersion: version)
            let profile = try await getJSON(session, request: profileRequest, token: token)
            let owner = profile["account"]["uuid"].string ?? profile["account_uuid"].string ?? profile["accountUuid"].string
            let org = profile["organization"]["uuid"].string ?? profile["organization_uuid"].string ?? profile["organizationUuid"].string
            guard owner?.lowercased() == token.accountID, org?.lowercased() == token.organizationID else {
                denied[token.tokenDigest] = .identityMismatch; throw UsageFailure.identityMismatch
            }
            try await validate(token)
            try checkCancellation(generation)
            // A verified plan remains useful when the subsequent usage endpoint denies a downgraded login.
            let email = profile["account"]["email_address"].string ?? profile["account"]["emailAddress"].string
            verifiedAccount = Account(id: token.accountID, email: email, organizationID: token.organizationID)
            verifiedPlan = (token.accountID, token.organizationID, AccountPlan.profile(profile), now())
            guard token.expiresAt > now().addingTimeInterval(15) else { throw UsageNotReady(reason: .expiring) }
            let request = try DesktopUsageProtocol.request(path: "/api/oauth/usage", token: token.value, codeVersion: version)
            let root = try await getJSON(session, request: request, token: token)
            try await validate(token)
            try checkCancellation(generation)
            let windows = UsageResponseParser.windows(root, at: now())
            guard !windows.isEmpty else { throw UsageFailure.invalidResponse }
            failures[token.quotaScope] = nil
            return UsageSnapshot(accountID: accountID, organizationID: token.organizationID, observedAt: now(), origin: .live, windows: windows)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                verifiedAccount = nil; verifiedPlan = nil
                attemptedTokens[accountID] = nil
                throw CancellationError()
            }
            if error is SwitchError {
                verifiedAccount = nil; verifiedPlan = nil
            } else if verifiedAccount != nil {
                do { try await validate(token); try checkCancellation(generation) }
                catch {
                    verifiedAccount = nil; verifiedPlan = nil
                    attemptedTokens[accountID] = nil
                    throw error
                }
            }
            if error is UsageCoolingDown || (error as? UsageFailure)?.isTransient == true || error is SwitchError {
                attemptedTokens[accountID] = nil
            }
            if error is UsageFailure || error is UsageCoolingDown || error is UsageNotReady || error is SwitchError { throw error }
            attemptedTokens[accountID] = nil
            backoff(token.quotaScope)
            throw UsageFailure.offline
        }
    }
    private func checkCancellation(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard generation == cancellationGeneration else { throw CancellationError() }
    }
    private func getJSON(_ session: URLSession, request: URLRequest, token: DesktopAccessToken) async throws -> JSONValue {
        let (data, http) = try await transport(session, request)
        switch http.statusCode {
        case 200: break
        case 401: denied[token.tokenDigest] = .unauthorized; throw UsageFailure.unauthorized
        case 403:
            let value = try? JSONDecoder().decode(JSONValue.self, from: data)
            let kind: UsageFailure = value?["error"]["type"].string == "missing_scope" ? .missingScopes : .forbidden
            denied[token.tokenDigest] = kind; throw kind
        case 429:
            hold(token.quotaScope, seconds: max(Self.spacing, retryAfter(http.value(forHTTPHeaderField: "Retry-After")) ?? Self.rateLimitWait))
            throw UsageCoolingDown(until: cooldowns[token.quotaScope]!)
        case 500...599, 408:
            backoff(token.quotaScope)
            if let seconds = retryAfter(http.value(forHTTPHeaderField: "Retry-After")) { hold(token.quotaScope, seconds: seconds) }
            throw UsageFailure.server
        default: throw UsageFailure.invalidResponse
        }
        guard data.count <= 1_048_576 else { throw UsageFailure.invalidResponse }
        guard let result = try? JSONDecoder().decode(JSONValue.self, from: data), result.object != nil else { throw UsageFailure.invalidResponse }
        return result
    }
    private static func send(_ session: URLSession, request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageFailure.invalidResponse }
        let limit = http.statusCode == 200 ? 1_048_576 : 16_384
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else {
                if http.statusCode != 200 { break }
                throw UsageFailure.invalidResponse
            }
            data.append(byte)
        }
        return (data, http)
    }
    private func backoff(_ scope: String) {
        let count = min(7, (failures[scope] ?? 0) + 1); failures[scope] = count
        hold(scope, seconds: min(Self.longestWait, Self.spacing * pow(2, Double(count - 1))))
    }
    private func hold(_ scope: String, seconds: TimeInterval) {
        cooldowns[scope] = max(cooldowns[scope] ?? .distantPast, now().addingTimeInterval(seconds))
    }
    private func retryAfter(_ header: String?) -> Double? {
        guard let header else { return nil }
        if let value = Double(header), value.isFinite, value >= 0 { return value }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: header).map { max(0, $0.timeIntervalSince(now())) }
    }
    private func reserve(_ token: DesktopAccessToken) throws {
        try schedulerLock {
            try loadState()
            if let old = legacyCooldowns[token.credentialDigest] { cooldowns[token.quotaScope] = max(cooldowns[token.quotaScope] ?? .distantPast, old) }
            if legacyDenied.contains(token.credentialDigest) { denied[token.tokenDigest] = .unauthorized }
            if let failure = denied[token.tokenDigest] { throw failure }
            if let until = cooldowns[token.quotaScope], until > now() { throw UsageCoolingDown(until: until) }
            hold(token.quotaScope, seconds: Self.spacing)
            try writeState()
        }
    }
    private func persist() throws { try schedulerLock { try loadState(); try writeState() } }
    private func schedulerLock<T>(_ body: () throws -> T) throws -> T {
        guard !storageFailed else { throw SwitchError.blocked(L10n.tr("Quota retry state could not be saved. Check local storage before retrying.")) }
        try SafeFiles.privateDirectory(environment.root)
        let path = environment.root.appendingPathComponent("usage-scheduler.lock")
        let fd = open(path.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SwitchError.unsafePath }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw SwitchError.busy }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    private func loadState() throws {
        let url = environment.root.appendingPathComponent("usage-cooldown.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let saved = try SafeFiles.json(url)
        let keys: Set<String> = ["version", "scopeCooldowns", "deniedTokens", "cooldowns", "deniedDigests",
                                 "cooldownDigest", "cooldownUntil", "deniedDigest"]
        guard let fields = saved.object, Set(fields.keys).isSubset(of: keys),
              saved["version"] == .null || saved["version"] == .number(2) else {
            throw Self.invalidRetryState
        }
        for key in ["scopeCooldowns", "deniedTokens", "cooldowns"] where saved[key] != .null {
            guard saved[key].object != nil else { throw Self.invalidRetryState }
        }
        for key in ["cooldownDigest", "deniedDigest"] where saved[key] != .null {
            guard saved[key].string != nil else { throw Self.invalidRetryState }
        }
        for (key, value) in saved["scopeCooldowns"].object ?? [:] {
            guard let until = Dates.parse(value) else { throw Self.invalidRetryState }
            cooldowns[key] = max(cooldowns[key] ?? .distantPast, until)
        }
        for (key, value) in saved["deniedTokens"].object ?? [:] {
            guard let raw = value.string, let failure = UsageFailure(rawValue: raw) else { throw Self.invalidRetryState }
            denied[key] = denied[key] ?? failure
        }
        for (key, value) in saved["cooldowns"].object ?? [:] {
            guard let until = Dates.parse(value) else { throw Self.invalidRetryState }
            legacyCooldowns[key] = until
        }
        if let key = saved["cooldownDigest"].string {
            guard let until = Dates.parse(saved["cooldownUntil"]) else { throw Self.invalidRetryState }
            legacyCooldowns[key] = until
        }
        if saved["deniedDigests"] != .null {
            guard let values = saved["deniedDigests"].array, values.allSatisfy({ $0.string != nil }) else { throw Self.invalidRetryState }
        }
        legacyDenied.formUnion((saved["deniedDigests"].array ?? []).compactMap(\.string))
        if let key = saved["deniedDigest"].string { legacyDenied.insert(key) }
    }
    private static var invalidRetryState: SwitchError {
        .blocked(L10n.tr("Quota retry state could not be saved. Check local storage before retrying."))
    }
    private func writeState() throws {
        cooldowns = cooldowns.filter { $0.value > now() }; legacyCooldowns = legacyCooldowns.filter { $0.value > now() }
        let value: JSONValue = .object([
            "version": .number(2), "scopeCooldowns": .object(cooldowns.mapValues { .number($0.timeIntervalSince1970) }),
            "deniedTokens": .object(denied.mapValues { .string($0.rawValue) }),
            "cooldowns": .object(legacyCooldowns.mapValues { .number($0.timeIntervalSince1970) }),
            "deniedDigests": .array(legacyDenied.sorted().map(JSONValue.string))
        ])
        try SafeFiles.atomicWrite(JSONEncoder().encode(value), to: environment.root.appendingPathComponent("usage-cooldown.json"))
    }
}
