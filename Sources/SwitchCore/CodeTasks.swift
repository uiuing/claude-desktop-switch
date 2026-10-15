import Foundation

public enum CodeTaskStatus: String, Equatable, Sendable {
    case running, permission, input, waiting, idle, notRunning, unknown
    public init(published status: String?, waitingFor: String?) {
        switch status {
        case "busy", "shell": self = .running
        case "idle": self = .idle
        case "waiting":
            switch waitingFor {
            case "permission prompt": self = .permission
            case "input needed": self = .input
            default: self = .waiting
            }
        default: self = .unknown
        }
    }
    public var needsAttention: Bool { [.permission, .input, .waiting].contains(self) }
    public var title: String {
        switch self {
        case .running: return L10n.tr("Running")
        case .permission: return L10n.tr("Waiting for permission")
        case .input: return L10n.tr("Waiting for your reply")
        case .waiting: return L10n.tr("Waiting for you")
        case .idle: return L10n.tr("Idle")
        case .notRunning: return L10n.tr("Not running")
        case .unknown: return L10n.tr("Status unknown")
        }
    }
    public var symbol: String {
        switch self {
        case .running: return "circle.dotted"
        case .permission: return "hand.raised.fill"
        case .input: return "bubble.left.fill"
        case .waiting: return "exclamationmark.circle.fill"
        case .idle: return "circle"
        case .notRunning: return "moon"
        case .unknown: return "questionmark.circle"
        }
    }
    private var order: Int { needsAttention ? 0 : self == .running ? 1 : self == .unknown ? 2 : 3 }
    public func precedes(_ other: Self) -> Bool { order < other.order }
}

public struct CodeTaskScope: Equatable, Sendable {
    public var accountID: String
    public var organizationID: String
    public init?(accountID: String, organizationID: String) {
        guard let account = UUID(uuidString: accountID), let org = UUID(uuidString: organizationID) else { return nil }
        self.accountID = account.uuidString.lowercased(); self.organizationID = org.uuidString.lowercased()
    }
    public func contains(_ session: Conversation) -> Bool {
        session.accountID == accountID && session.organizationID == organizationID && session.kind == .code && !session.archived
    }
}

public struct CodeTaskProcess: Hashable, Sendable {
    public var pid: Int32
    public var started: UInt64
    public init(pid: Int32, started: UInt64) { self.pid = pid; self.started = started }
}

public struct CodeTask: Identifiable, Equatable, Sendable {
    public var id: String { conversation.id }
    public var conversation: Conversation
    public var status: CodeTaskStatus
    public var process: CodeTaskProcess?
    public init(conversation: Conversation, status: CodeTaskStatus, process: CodeTaskProcess? = nil) {
        self.conversation = conversation; self.status = status; self.process = process
    }
    /// Desktop's own session links use this route. Never add a prompt or a resume command.
    public var destination: URL? {
        let id = conversation.sessionID
        guard conversation.kind == .code, !conversation.archived, LocalID.isSession(id), !id.hasPrefix("session_") else { return nil }
        var url = URLComponents()
        url.scheme = "claude"; url.host = "claude.ai"; url.path = "/epitaxy/" + id
        return url.url
    }
}

public struct CodeTaskSnapshot: Equatable, Sendable {
    public enum Availability: Equatable, Sendable { case connecting, ready, incomplete, switching, offline, unavailable }
    public var scope: CodeTaskScope?
    public var availability: Availability
    public var tasks: [CodeTask]
    public var processes: Set<CodeTaskProcess>
    public init(scope: CodeTaskScope? = nil, availability: Availability, tasks: [CodeTask] = [], processes: Set<CodeTaskProcess> = []) {
        self.scope = scope; self.availability = availability; self.tasks = tasks; self.processes = processes
    }
    public var running: Int? { availability == .ready ? tasks.filter { $0.status == .running }.count : nil }
    public var waiting: Int? { availability == .ready ? tasks.filter { $0.status.needsAttention }.count : nil }
    public func ordered(follows: [FollowRule]) -> [CodeTask] {
        tasks.sorted { a, b in
            let af = follows.contains { $0.matches(a.conversation) }, bf = follows.contains { $0.matches(b.conversation) }
            if af != bf { return af }
            if a.status.precedes(b.status) { return true }
            if b.status.precedes(a.status) { return false }
            if a.conversation.title != b.conversation.title { return a.conversation.title.localizedStandardCompare(b.conversation.title) == .orderedAscending }
            return a.id < b.id
        }
    }
    public var detail: String {
        switch availability {
        case .connecting: return L10n.tr("Connecting to this account…")
        case .ready: return L10n.tr("{0} running · {1} waiting", (running ?? 0).formatted(.number.locale(L10n.locale)),
                                   (waiting ?? 0).formatted(.number.locale(L10n.locale)))
        case .incomplete: return L10n.tr("Some task states are unavailable. Counts are hidden.")
        case .switching: return L10n.tr("Switching accounts. Reconnecting task states…")
        case .offline: return L10n.tr("Claude is not running")
        case .unavailable: return L10n.tr("Task states are unavailable")
        }
    }
}

/// An epoch also changes for A → B → A, sleep, and operations that fail and roll back.
public struct CodeTaskBinding: Sendable {
    public struct Ticket: Equatable, Sendable { public let epoch: UUID; public let scope: CodeTaskScope }
    public private(set) var epoch = UUID()
    public private(set) var snapshot = CodeTaskSnapshot(availability: .connecting)
    public private(set) var excludedProcesses = Set<CodeTaskProcess>()
    private var lastProcesses = Set<CodeTaskProcess>()
    public init() {}
    public mutating func invalidate(_ availability: CodeTaskSnapshot.Availability, excludeProcesses: Bool = false) {
        if excludeProcesses { excludedProcesses.formUnion(lastProcesses); lastProcesses = [] }
        epoch = UUID(); snapshot = .init(scope: excludeProcesses ? nil : snapshot.scope, availability: availability)
    }
    public mutating func begin(_ scope: CodeTaskScope) -> Ticket {
        if snapshot.scope != scope {
            invalidate(.connecting, excludeProcesses: true)
            snapshot.scope = scope
        }
        return Ticket(epoch: epoch, scope: scope)
    }
    public func isCurrent(_ ticket: Ticket) -> Bool { epoch == ticket.epoch && snapshot.scope == ticket.scope }
    @discardableResult public mutating func accept(_ result: CodeTaskSnapshot, for ticket: Ticket) -> Bool {
        guard isCurrent(ticket), result.scope == ticket.scope else { return false }
        var result = result
        if !result.processes.isDisjoint(with: excludedProcesses) { result.availability = .incomplete }
        for index in result.tasks.indices where result.tasks[index].process.map(excludedProcesses.contains) == true {
            result.tasks[index].status = .unknown; result.availability = .incomplete
        }
        if [.ready, .incomplete, .offline].contains(result.availability) {
            excludedProcesses.formIntersection(result.processes); lastProcesses = result.processes
        }
        snapshot = result
        return true
    }
}
