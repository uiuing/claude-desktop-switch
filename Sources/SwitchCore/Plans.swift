import Foundation

public enum SessionTransferMode: String, Codable, CaseIterable, Sendable {
    case move, copy
    public var title: String { self == .move ? L10n.tr("Move") : L10n.tr("Copy") }
    public var explanation: String {
        self == .move ? L10n.tr("After moving, this conversation is removed from the original account.") : L10n.tr("After copying, both accounts keep this conversation.")
    }
}
public enum FileExpectation: Codable, Equatable, Sendable {
    case absent
    case sha256(String)
}

/// `signOut` moves the signed-in login into Switch's vault so Claude opens to its sign-in screen.
/// It never signs out on the server, which would void the login Switch keeps.
public enum OperationKind: String, Codable, Sendable { case capture, switchAccount, signOut, migrate, recover }
public struct OperationPlan: Identifiable, Codable, Sendable {
    public var id: UUID = UUID()
    public var kind: OperationKind
    public var createdAt: Date = Date()
    public var sourceAccountID: String?
    public var targetAccountID: String
    public var configDigest: String
    public var steps: [String]
    public var conversationIDs: [String] = []
    public var sourceDigests: [String: String] = [:]
    public var warnings: [String] = []
    public var transferModes: [String: SessionTransferMode] = [:]
    public var destinationExpectations: [String: FileExpectation] = [:]
    public var targetOrganizationID: String?
    public func transferMode(for id: String) -> SessionTransferMode { transferModes[id] ?? .move }
    public init(kind: OperationKind, sourceAccountID: String?, targetAccountID: String, configDigest: String,
                steps: [String], conversationIDs: [String] = [], warnings: [String] = []) {
        self.kind = kind; self.sourceAccountID = sourceAccountID; self.targetAccountID = targetAccountID
        self.configDigest = configDigest; self.steps = steps; self.conversationIDs = conversationIDs; self.warnings = warnings
    }
    public func validate(now: Date = Date(), digest: String) throws {
        guard now.timeIntervalSince(createdAt) < 120, now >= createdAt, digest == configDigest else { throw SwitchError.changed }
        guard UUID(uuidString: targetAccountID) != nil else { throw SwitchError.malformed(L10n.tr("Account identity information is incomplete.")) }
    }
}

public enum SessionLibrary {
    public static func sorted(_ sessions: [Conversation], order: SessionSort, accounts: [Account]) -> [Conversation] {
        let labels = Dictionary(accounts.map { ($0.id, $0.email ?? $0.id) }, uniquingKeysWith: { a, _ in a })
        return sessions.sorted {
            if order == .account && $0.accountID != $1.accountID {
                let a = labels[$0.accountID] ?? $0.accountID, b = labels[$1.accountID] ?? $1.accountID
                if a != b { return a.localizedStandardCompare(b) == .orderedAscending }
                return $0.accountID < $1.accountID
            }
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.id < $1.id
        }
    }
    public static func followedSessions(_ sessions: [Conversation], rules: [FollowRule], activeAccountID: String?,
                                       targetAccountID: String) -> [Conversation] {
        let candidates = sessions.filter { session in
            !session.archived && session.accountID != targetAccountID && rules.contains {
                $0.matches(session) && ($0.mode == .allSavedAccounts || $0.targetAccountIDs.contains(targetAccountID))
            }
        }.sorted {
            if ($0.accountID == activeAccountID) != ($1.accountID == activeAccountID) { return $0.accountID == activeAccountID }
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.id < $1.id
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.sessionID).inserted }
    }

    public static func migrationBlocker(_ session: Conversation, target: Account) -> String? {
        guard session.kind == .code else {
            return session.kind == .cowork ? L10n.tr("Cowork includes sandbox and attachment state. Only folder inspection is currently available.") : L10n.tr("Cloud Chat has no local conversation file that can be migrated directly.")
        }
        guard session.cliSessionID != nil else { return L10n.tr("This conversation has no verifiable local transcript.") }
        guard session.accountID != target.id else { return L10n.tr("This conversation already belongs to this account.") }
        guard target.organizationID != nil else { return L10n.tr("The target account has no organization information. Sign in to Desktop and scan it first.") }
        return nil
    }
}
