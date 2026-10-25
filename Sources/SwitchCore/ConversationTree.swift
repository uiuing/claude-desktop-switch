import Foundation

/// Session indexes form account/organization-local trees. Transcript subagents are not sidebar sessions.
public struct ConversationTree: Sendable {
    private let sessions: [Conversation]
    private let byID: [String: Conversation]
    private let rootIDs: [String: String]
    private let groups: [String: [Conversation]]
    private let invalid: Set<String>

    public init(_ sessions: [Conversation]) {
        self.sessions = sessions
        byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func key(_ session: Conversation, _ id: String) -> String {
            session.accountID.lowercased() + "/" + session.organizationID.lowercased() + "/" + id.lowercased()
        }
        let indexes = Dictionary(grouping: sessions.filter { $0.kind == .code }, by: { key($0, $0.sessionID) })
        var roots: [String: String] = [:], bad = Set<String>()
        for session in sessions {
            var current = session, visited = Set<String>(), chain: [String] = []
            while true {
                guard visited.insert(current.id).inserted, chain.count < 128,
                      current.invalidLineage != true,
                      current.kind != .code || indexes[key(current, current.sessionID)]?.count == 1 else {
                    bad.formUnion(chain + [current.id]); break
                }
                chain.append(current.id)
                guard current.kind == .code, let parent = current.parentSessionID else {
                    for id in chain { roots[id] = current.id }
                    break
                }
                guard let matches = indexes[key(current, parent)], matches.count == 1,
                      let next = matches.first else { bad.formUnion(chain); break }
                current = next
            }
        }
        // Never hide an unresolved record under a guessed parent.
        for id in bad { roots[id] = id }
        rootIDs = roots; invalid = bad
        groups = Dictionary(grouping: sessions, by: { roots[$0.id] ?? $0.id })
    }

    public var roots: [Conversation] { sessions.filter { rootIDs[$0.id] == $0.id } }
    public var visibleRoots: [Conversation] { roots.filter { members(of: $0).contains { !$0.archived } } }
    public func root(of session: Conversation) -> Conversation { rootIDs[session.id].flatMap { byID[$0] } ?? session }
    public func members(of session: Conversation) -> [Conversation] { groups[rootIDs[session.id] ?? session.id] ?? [session] }
    public func childCount(of session: Conversation) -> Int {
        members(of: session).filter { $0.id != root(of: session).id && !$0.archived }.count
    }
    public func modifiedAt(of session: Conversation) -> Date { members(of: session).map(\.modifiedAt).max() ?? session.modifiedAt }
    public func isValid(_ session: Conversation) -> Bool { members(of: session).allSatisfy { !invalid.contains($0.id) } }
    public func recentlyActive(_ session: Conversation, accountID: String?, now: Date) -> Bool {
        members(of: session).contains { SessionLibrary.recentlyActiveForSwitch($0, activeAccountID: accountID, now: now) }
    }

    public func expanded(_ selected: [Conversation]) throws -> [Conversation] {
        var seen = Set<String>(), result: [Conversation] = []
        for session in selected {
            guard byID[session.id] != nil, isValid(session) else { throw Self.unresolved }
            for member in members(of: session) where seen.insert(member.id).inserted { result.append(member) }
        }
        return result
    }

    public static var unresolved: SwitchError {
        .blocked(L10n.tr("The conversation's parent or child records could not be verified. Refresh and try again."))
    }
}

public enum ConversationLineage {
    /// The parser only identifies relationships. Migration preserves the complete original record.
    public static func read(_ record: JSONValue, sessionID: String) -> (parent: String?, invalid: Bool) {
        if record["lineageDetached"].bool == true { return (nil, false) }
        func present(_ value: JSONValue) -> Bool { value != .null }
        let fork = record["forkedFromSessionId"], spawned = record["spawnedFrom"]
        guard (!present(fork) || fork.string.map(LocalID.isSession) == true),
              (!present(spawned) || (spawned.object != nil && spawned["sessionId"].string.map(LocalID.isSession) == true)) else {
            return (nil, true)
        }
        let parent: String?
        if spawned["sideSession"].bool == true, spawned["userFork"].bool != true,
           fork.string == nil || fork.string == spawned["sessionId"].string || fork.string == spawned["deletedParent"]["sessionId"].string {
            parent = spawned["sessionId"].string
        } else { parent = fork.string ?? spawned["sessionId"].string }
        return (parent, parent?.lowercased() == sessionID.lowercased())
    }
}
