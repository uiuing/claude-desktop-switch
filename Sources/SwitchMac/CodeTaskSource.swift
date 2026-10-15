import AppKit
import Foundation
import SwitchCore
import SwitchStorage

public actor CodeTaskSource {
    private let environment: MacEnvironment
    private let reader: CodeTaskReader
    private let runningApplications: @Sendable () async -> [Int32]
    private let processSnapshot: @Sendable () throws -> [ProcessEntry]
    private var loginProbe: LoginProbe.Cache
    private var loginScope: CodeTaskScope?
    private var loginDesktop: CodeTaskProcess?
    public init(environment: MacEnvironment) {
        self.init(environment: environment, runningApplications: {
            await MainActor.run {
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").map(\.processIdentifier)
            }
        }, processSnapshot: { try ProcessTable.snapshot() })
    }
    init(environment: MacEnvironment, runningApplications: @escaping @Sendable () async -> [Int32],
         processSnapshot: @escaping @Sendable () throws -> [ProcessEntry], loginProbe: LoginProbe.Cache = .init()) {
        self.environment = environment
        reader = CodeTaskReader(desktop: environment.desktop, registry: environment.home.appendingPathComponent(".claude/sessions"))
        self.runningApplications = runningApplications; self.processSnapshot = processSnapshot; self.loginProbe = loginProbe
    }
    public func scan(scope: CodeTaskScope, followed: [Conversation]) async -> CodeTaskSnapshot {
        do {
            let before = try await context(scope)
            guard let before else { return .init(scope: scope, availability: .offline) }
            let result = await reader.scan(scope: scope, processes: before.processes, followed: followed)
            guard let after = try await context(scope), before == after else {
                return .init(scope: scope, availability: .connecting)
            }
            return result
        } catch { loginProbe.invalidate(); return .init(scope: scope, availability: .unavailable) }
    }
    private struct Context: Equatable {
        var desktop: CodeTaskProcess
        var processes: Set<CodeTaskProcess>
    }
    private func context(_ scope: CodeTaskScope) async throws -> Context? {
        let owners = await runningApplications()
        if owners.isEmpty { loginProbe.invalidate(); return nil }
        guard owners.count == 1, try environment.currentAccount() == scope.accountID else { throw SwitchError.changed }
        let all = try processSnapshot()
        guard let owner = all.first(where: { $0.pid == owners[0] }) else { throw SwitchError.changed }
        let desktop = CodeTaskProcess(pid: owner.pid, started: owner.started)
        if loginScope != scope || loginDesktop != desktop { loginProbe.invalidate(); loginScope = scope; loginDesktop = desktop }
        guard loginProbe.signedIn(cookies: environment.desktop.appendingPathComponent("Cookies")) == true else { throw SwitchError.changed }
        let processes = Self.codeProcesses(all, owners: Set(owners), codeBuilds: environment.desktop.appendingPathComponent("claude-code").path + "/")
        return Context(desktop: desktop, processes: processes)
    }
    /// Only root Code engines descended from this Desktop instance. Child agents are not separate tasks.
    static func codeProcesses(_ all: [ProcessEntry], owners: Set<Int32>, codeBuilds: String) -> Set<CodeTaskProcess> {
        let tree = ProcessTable.tree(of: owners, in: all)
        let candidates = all.filter { tree.contains($0.key) && (ProcessTable.isDesktopCode($0, codeBuilds: codeBuilds) || ProcessTable.isClaudeCode($0)) }
        let ids = Set(candidates.map(\.pid)), parents = Dictionary(all.map { ($0.pid, $0.parent) }, uniquingKeysWith: { a, _ in a })
        return Set(candidates.filter { entry in
            var parent = entry.parent
            for _ in 0..<64 {
                if ids.contains(parent) { return false }
                guard let next = parents[parent], next > 1 else { return true }
                parent = next
            }
            return false
        }.map { .init(pid: $0.pid, started: $0.started) })
    }
}
