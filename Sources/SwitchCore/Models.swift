import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var number: Double? { if case .number(let v) = self { return v }; return nil }
    public var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    public var array: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public subscript(_ key: String) -> JSONValue { object?[key] ?? .null }
}

public enum SwitchError: LocalizedError {
    case blocked(String), malformed(String), unsafePath, changed, busy, missing(String)
    public var errorDescription: String? {
        switch self {
        case .blocked(let s), .malformed(let s), .missing(let s): return s
        case .unsafePath: return L10n.tr("The path contains links, out-of-bounds locations or unsupported files. Stopped.")
        case .changed: return L10n.tr("Data changed after the preview. Preview again.")
        case .busy: return L10n.tr("Another operation is running. Try again later.")
        }
    }
}

public enum BuildAccess {
    public static var allowsClaudeWrites: Bool {
        #if CLAUDE_WRITE_ENABLED
        return true
        #else
        return false
        #endif
    }
    public static func requireClaudeWrites() throws {
        guard allowsClaudeWrites else {
            throw SwitchError.blocked(L10n.tr("This build is read-only. You can inspect data and operation previews; Claude credentials, processes and conversations will not be changed."))
        }
    }
}

public struct Account: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    /// Only set from a source that reported it for this exact account UUID; never derived or guessed.
    public var email: String?
    /// A server-confirmed email cannot be overwritten by local Desktop or Code caches.
    public var emailVerifiedAt: Date?
    public var organizationID: String?
    /// When the server confirmed `organizationID` for this login's own token. Local files and Claude Code,
    /// which can use another organization of the same account, then no longer decide it.
    public var organizationVerifiedAt: Date?
    /// Organization plan, including explicit "Free"; nil means unknown.
    public var plan: String?
    /// When `plan` was observed; nil plan readings explicitly replace an older known label.
    public var planObservedAt: Date?
    /// A server-confirmed plan is not replaced by a local cache file's modification time.
    public var planVerifiedAt: Date?
    public var hasSnapshot: Bool
    public var lastSavedAt: Date?
    /// Credential fingerprint and Claude version of the saved snapshot; a change means it must be saved again.
    public var snapshotFingerprint: String?
    /// Legacy invalid-login marker. Local cookie absence and access-token expiry must not set it.
    /// LibraryStore clears old heuristic flags; this does not establish that the login is valid.
    public var loginInvalidAt: Date?
    public init(id: String, email: String? = nil, organizationID: String? = nil,
                hasSnapshot: Bool = false, lastSavedAt: Date? = nil, snapshotFingerprint: String? = nil) {
        self.id = id; self.email = email; self.organizationID = organizationID
        self.hasSnapshot = hasSnapshot; self.lastSavedAt = lastSavedAt; self.snapshotFingerprint = snapshotFingerprint
    }
    /// Masks only the middle of the local part; its first and last characters and the domain stay readable.
    public var maskedEmail: String? {
        guard let email, let at = email.firstIndex(of: "@") else { return nil }
        let name = email[..<at]
        let keep = name.count >= 6 ? 2 : name.count >= 3 ? 1 : 0
        let masked = keep > 0 ? String(name.prefix(keep)) + "•••" + String(name.suffix(keep)) : String(name.prefix(1)) + "•••"
        return masked + String(email[at...])
    }
    /// A plan is per organization, so it does not survive a change of organization.
    public mutating func setOrganization(_ organizationID: String) {
        guard organizationID != self.organizationID else { return }
        self.organizationID = organizationID; plan = nil; planObservedAt = nil; planVerifiedAt = nil; organizationVerifiedAt = nil
    }
    public mutating func confirmOrganization(_ organizationID: String, at date: Date) {
        setOrganization(organizationID); organizationVerifiedAt = date
    }
    @discardableResult
    public mutating func observeEmail(_ email: String?, verifiedAt date: Date? = nil, fillOnly: Bool = false) -> Bool {
        guard let email, !fillOnly || self.email == nil else { return false }
        if let date {
            guard date >= (emailVerifiedAt ?? .distantPast) else { return false }
            emailVerifiedAt = date
        } else if emailVerifiedAt != nil { return false }
        let changed = self.email != email
        self.email = email
        return changed
    }
    /// Server readings outrank local cache timestamps, including an explicitly unknown plan.
    @discardableResult
    public mutating func observePlan(_ plan: String?, organizationID: String, at date: Date, verified: Bool = false) -> Bool {
        guard organizationID == self.organizationID, verified || planVerifiedAt == nil,
              date >= ((verified ? planVerifiedAt : planObservedAt) ?? .distantPast) else { return false }
        if !verified, planObservedAt != nil, self.plan == plan { return false }
        let changed = self.plan != plan
        self.plan = plan; planObservedAt = date
        if verified { planVerifiedAt = date }
        return changed
    }
    public var planTitle: String { plan == "Free" ? L10n.tr("Free") : plan ?? L10n.tr("Plan unknown") }
    public var shortID: String { String(id.prefix(8)) }
    /// Claude has no account name or avatar locally; the email, or else the raw ID, is all that can be shown.
    public func identity(maskingEmail: Bool) -> String {
        (maskingEmail ? maskedEmail : email) ?? "ID " + shortID
    }
}

public enum SessionKind: String, Codable, CaseIterable, Sendable {
    case code, cowork, chat
    public var title: String { switch self { case .code: return "Code"; case .cowork: return "Cowork"; case .chat: return L10n.tr("Chat") } }
}
public struct Conversation: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var sessionID: String
    public var accountID: String
    public var organizationID: String
    public var title: String
    public var kind: SessionKind
    public var modifiedAt: Date
    public var model: String?
    public var project: String?
    public var recordRelativePath: String
    public var cliSessionID: String?
    public var archived: Bool
    public init(id: String, sessionID: String, accountID: String, organizationID: String, title: String,
                kind: SessionKind, modifiedAt: Date, model: String? = nil, project: String? = nil,
                recordRelativePath: String, cliSessionID: String? = nil, archived: Bool = false) {
        self.id = id; self.sessionID = sessionID; self.accountID = accountID; self.organizationID = organizationID
        self.title = title; self.kind = kind; self.modifiedAt = modifiedAt; self.model = model; self.project = project
        self.recordRelativePath = recordRelativePath; self.cliSessionID = cliSessionID; self.archived = archived
    }
}

public enum SessionSort: String, CaseIterable, Codable, Sendable { case time, account }
public enum FollowMode: String, Codable, Sendable { case selectedAccounts, allSavedAccounts }
public struct FollowRule: Codable, Identifiable, Sendable {
    public var id: String { conversationID }
    public var conversationID: String
    public var sessionID: String?
    public var transferMode: SessionTransferMode
    public var mode: FollowMode
    public var targetAccountIDs: [String]
    public init(conversationID: String, sessionID: String? = nil, transferMode: SessionTransferMode = .move,
                mode: FollowMode = .allSavedAccounts, targetAccountIDs: [String] = []) {
        self.conversationID = conversationID; self.sessionID = sessionID; self.transferMode = transferMode
        self.mode = mode; self.targetAccountIDs = targetAccountIDs
    }
    public func matches(_ session: Conversation) -> Bool {
        if let sessionID { return session.sessionID == sessionID }
        // Legacy rules included the desktop session ID at the end of the index identity.
        return conversationID == session.id || conversationID.split(separator: "/").last.map(String.init) == session.sessionID
    }
    private enum CodingKeys: String, CodingKey { case conversationID, sessionID, transferMode, mode, targetAccountIDs }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversationID = try c.decode(String.self, forKey: .conversationID)
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        transferMode = try c.decodeIfPresent(SessionTransferMode.self, forKey: .transferMode) ?? .move
        mode = try c.decodeIfPresent(FollowMode.self, forKey: .mode) ?? .allSavedAccounts
        targetAccountIDs = try c.decodeIfPresent([String].self, forKey: .targetAccountIDs) ?? []
    }
}

public struct Preferences: Codable, Sendable {
    public var maskEmail = false
    public var sessionSort: SessionSort = .time
    public var quotaRefresh = QuotaRefreshPreferences()
    public init() {}
    private enum CodingKeys: String, CodingKey { case maskEmail, sessionSort, quotaRefresh }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maskEmail = try c.decodeIfPresent(Bool.self, forKey: .maskEmail) ?? false
        sessionSort = try c.decodeIfPresent(SessionSort.self, forKey: .sessionSort) ?? .time
        quotaRefresh = try c.decodeIfPresent(QuotaRefreshPreferences.self, forKey: .quotaRefresh) ?? .init()
    }
}
public struct LibraryState: Codable, Sendable {
    public var schemaVersion = 1
    public var accounts: [Account] = []
    public var usage: [String: UsageSnapshot] = [:]
    public var usageHistory: [String: [UsageSnapshot]] = [:]
    public var follows: [FollowRule] = []
    public var newAccountFollowUp: NewAccountFollowUp?
    public var preferences = Preferences()
    public init() {}
}

public struct LocalInventory: Sendable {
    /// The signed-in account. nil while Claude shows its sign-in screen.
    public var activeAccountID: String?
    /// The account config.json still names, signed in or not.
    public var lastKnownAccountID: String?
    /// nil when the login state could not be read.
    public var signedIn: Bool?
    public var accounts: [Account]
    /// Emails explicitly attributed to account UUIDs in Desktop's cache; Code only fills gaps.
    public var desktopEmails: [String: String]
    public var conversations: [Conversation]
    public var usage: UsageSnapshot?
    public var cachedUsage: [String: UsageSnapshot]
    public var warnings: [String]
    public var scannedAt: Date
    public init(activeAccountID: String?, accounts: [Account], conversations: [Conversation],
                usage: UsageSnapshot?, warnings: [String], scannedAt: Date = Date(), cachedUsage: [String: UsageSnapshot] = [:],
                lastKnownAccountID: String? = nil, signedIn: Bool? = nil, desktopEmails: [String: String] = [:]) {
        self.activeAccountID = activeAccountID; self.accounts = accounts; self.conversations = conversations
        self.desktopEmails = desktopEmails
        self.lastKnownAccountID = lastKnownAccountID ?? activeAccountID; self.signedIn = signedIn
        self.usage = usage; self.warnings = warnings; self.scannedAt = scannedAt; self.cachedUsage = cachedUsage
    }
}

public enum Dates {
    public static func parse(_ value: JSONValue) -> Date? {
        if let n = value.number, n.isFinite, n > 0 {
            return Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
        }
        guard let s = value.string else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

public enum LocalID {
    public static func isSession(_ value: String) -> Bool {
        if UUID(uuidString: value) != nil { return true }
        for prefix in ["local_", "session_"] where value.hasPrefix(prefix) {
            let tail = String(value.dropFirst(prefix.count))
            if UUID(uuidString: tail) != nil { return true }
        }
        return false
    }
}

public protocol InventoryReader: Sendable { func scan() async throws -> LocalInventory }
public protocol UsageProvider: Sendable { func fetchCurrent(accountID: String) async throws -> UsageSnapshot }
public protocol AccountVault: Sendable { func contains(accountID: String) async -> Bool }
public protocol TranscriptReader: Sendable { func scan(since: Date) async throws -> TokenReport }
public protocol SwitchService: Sendable {
    func prepare(kind: OperationKind, target: Account, sessions: [Conversation], transferModes: [String: SessionTransferMode]) async throws -> OperationPlan
    func execute(_ plan: OperationPlan, confirmedPlanID: UUID, target: Account, sessions: [Conversation]) async throws -> OperationResult
    func pendingRecovery() async throws -> [String]
    func recover(transactionID: String) async throws
}
