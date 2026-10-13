import Foundation
import SwitchCore
import SwitchStorage

private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
/// The signed-in login cannot be read yet, e.g. Claude is still starting or renewing its own token.
public struct UsageNotReady: LocalizedError {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}
/// The server was asked about this login too recently.
public struct UsageCoolingDown: LocalizedError {
    public let until: Date
    public var errorDescription: String? {
        L10n.tr("Quota was just read. Try again in {0} seconds.", L10n.argument(max(1, Int(ceil(until.timeIntervalSinceNow)))))
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
/// Reads the signed-in account's quota as Claude Code's `/usage` does: same endpoint, headers and per-login
/// back-off. Only the access token Claude Desktop already holds is used, and it is never renewed here.
public actor ActiveUsageClient: UsageProvider {
    /// Minimum spacing between reads for one login. 429 and 403 wait for Retry-After, else five minutes, as Claude Code does.
    static let spacing: TimeInterval = 60, rateLimitWait: TimeInterval = 300, longestWait: TimeInterval = 3600
    private let environment: MacEnvironment
    private var cooldown: (digest: String, until: Date)?
    private var deniedDigest: String?
    private var inFlight = false
    private var verifiedTokenDigest: String?
    private var verifiedAccount: Account?
    private var verifiedPlan: (accountID: String, organizationID: String, plan: String?, observedAt: Date)?
    public init(environment: MacEnvironment) {
        self.environment = environment
        if let saved = try? SafeFiles.json(environment.root.appendingPathComponent("usage-cooldown.json")) {
            if let digest = saved["cooldownDigest"].string, let until = Dates.parse(saved["cooldownUntil"]) { cooldown = (digest, until) }
            deniedDigest = saved["deniedDigest"].string
        }
    }
    public func identity() -> Account? { verifiedAccount }
    /// The server-reported plan, handed out once per profile check. A nil plan means no paid plan was reported.
    public func takeVerifiedPlan() -> (accountID: String, organizationID: String, plan: String?, observedAt: Date)? {
        defer { verifiedPlan = nil }
        return verifiedPlan
    }
    public func fetchCurrent(accountID: String) async throws -> UsageSnapshot {
        try await fetchCurrent(accountID: accountID, allowKeychainPrompt: false)
    }
    /// A keychain prompt is allowed only when the user asked for this read.
    public func fetchCurrent(accountID: String, allowKeychainPrompt: Bool) async throws -> UsageSnapshot {
        guard !inFlight else { throw SwitchError.busy }
        inFlight = true; defer { inFlight = false }
        guard try environment.currentAccount() == accountID else { throw UsageNotReady(message: SwitchError.changed.localizedDescription) }
        let environment = environment
        // An approval prompt can stay open indefinitely; it must not hold a Swift concurrency thread.
        let token: DesktopAccessToken = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try DesktopTokenReader.read(environment: environment, expectedAccount: accountID, allowPrompt: allowKeychainPrompt)
                })
            }
        }
        guard deniedDigest != token.credentialDigest else { throw SwitchError.blocked(L10n.tr("The login was rejected. Wait for Claude to update its credentials before retrying.")) }
        if let cooldown, cooldown.digest == token.credentialDigest, cooldown.until > Date() { throw UsageCoolingDown(until: cooldown.until) }
        guard let version = ClaudeCodeVersion.installed(environment) else {
            throw SwitchError.missing(L10n.tr("Claude Code was not found, so quota cannot be read the native way."))
        }
        hold(token.credentialDigest, for: Self.spacing)
        defer { saveCooldown() }
        let delegate = NoRedirect()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10; configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer " + token.value, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("claude-code/" + version, forHTTPHeaderField: "User-Agent")
        do {
            let tokenDigest = digest(Data(token.value.utf8))
            if verifiedTokenDigest != tokenDigest {
                var profileRequest = request
                profileRequest.url = URL(string: "https://api.anthropic.com/api/oauth/profile")!
                let profile = try await getJSON(session, request: profileRequest, tokenDigest: token.credentialDigest)
                let owner = profile["account"]["uuid"].string ?? profile["account_uuid"].string ?? profile["accountUuid"].string
                let org = profile["organization"]["uuid"].string ?? profile["organization_uuid"].string ?? profile["organizationUuid"].string
                guard owner?.lowercased() == token.accountID, org?.lowercased() == token.organizationID else {
                    deniedDigest = token.credentialDigest
                    throw SwitchError.blocked(L10n.tr("The online identity does not match Desktop. Quota lookup was stopped."))
                }
                let email = profile["account"]["email_address"].string ?? profile["account"]["emailAddress"].string ?? profile["account"]["email"].string
                verifiedAccount = Account(id: token.accountID, email: email, organizationID: token.organizationID)
                verifiedTokenDigest = tokenDigest
                let max = profile["account"]["has_claude_max"].bool, pro = profile["account"]["has_claude_pro"].bool
                if max != nil || pro != nil {
                    let tier = profile["organization"]["rate_limit_tier"].string
                    let plan = max == true ? DesktopProfile.plan(tier: tier, capabilities: ["claude_max"])
                        : pro == true ? "Pro" : DesktopProfile.plan(tier: tier, capabilities: [])
                    verifiedPlan = (token.accountID, token.organizationID, plan, Date())
                }
            }
            guard try environment.currentAccount() == token.accountID else { throw SwitchError.changed }
            let root = try await getJSON(session, request: request, tokenDigest: token.credentialDigest)
            guard try environment.currentAccount() == token.accountID,
                  try environment.credentialDigest() == token.credentialDigest else { throw SwitchError.changed }
            var windows: [QuotaWindow] = []
            for key in ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus"] {
                if let used = root[key]["utilization"].number, used.isFinite, (0...100).contains(used) {
                    windows.append(.init(id: key, title: L10n.quotaTitle(key, fallback: key), usedPercent: used,
                                         resetsAt: Dates.parse(root[key]["resets_at"])))
                }
            }
            for limit in root["limits"].array ?? [] {
                guard let model = limit["scope"]["model"]["display_name"].string,
                      let used = limit["percent"].number ?? limit["utilization"].number,
                      used.isFinite, (0...100).contains(used) else { continue }
                let id = "model:" + model
                if !windows.contains(where: { $0.id == id }) {
                    windows.append(.init(id: id, title: model, usedPercent: used, resetsAt: Dates.parse(limit["resets_at"])))
                }
            }
            guard !windows.isEmpty else { throw SwitchError.malformed(L10n.tr("The quota format has changed. The last reading is retained.")) }
            return UsageSnapshot(accountID: accountID, organizationID: token.organizationID, observedAt: Date(), origin: .live, windows: windows)
        } catch {
            if let error = error as? SwitchError { throw error }
            throw SwitchError.blocked(L10n.tr("The quota service is unavailable. The last reading is retained; retrying is delayed."))
        }
    }
    private func getJSON(_ session: URLSession, request: URLRequest, tokenDigest: String) async throws -> JSONValue {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw SwitchError.malformed(L10n.tr("The quota service did not return a valid response.")) }
        if http.statusCode == 401 { deniedDigest = tokenDigest }
        if http.statusCode == 429 || http.statusCode == 403 {
            let wait = retryAfter(http.value(forHTTPHeaderField: "Retry-After")) ?? 0
            hold(tokenDigest, for: min(wait > 0 ? wait : Self.rateLimitWait, Self.longestWait))
        }
        guard http.statusCode == 200 else { throw SwitchError.blocked(L10n.tr("Quota request failed ({0}). The last reading is retained.", L10n.argument(http.statusCode))) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_048_576 else { throw SwitchError.malformed(L10n.tr("The quota response exceeds the size limit.")) }
            data.append(byte)
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    private func hold(_ digest: String, for seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        if let cooldown, cooldown.digest == digest, cooldown.until > until { return }
        cooldown = (digest, until)
    }
    private func retryAfter(_ header: String?) -> Double? {
        guard let header else { return nil }
        if let seconds = Double(header), seconds.isFinite { return max(0, seconds) }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: header).map { max(0, $0.timeIntervalSinceNow) }
    }
    private func saveCooldown() {
        // Only our own nonsecret scheduler state is persisted, so relaunching cannot bypass a 429 wait.
        do {
            try SafeFiles.privateDirectory(environment.root)
            let value: JSONValue = .object(["cooldownDigest": cooldown.map { .string($0.digest) } ?? .null,
                                           "cooldownUntil": cooldown.map { .number($0.until.timeIntervalSince1970) } ?? .null,
                                           "deniedDigest": deniedDigest.map(JSONValue.string) ?? .null])
            try SafeFiles.atomicWrite(JSONEncoder().encode(value), to: environment.root.appendingPathComponent("usage-cooldown.json"))
        } catch { /* The in-process cooldown remains authoritative if the disk is unavailable. */ }
    }
}
