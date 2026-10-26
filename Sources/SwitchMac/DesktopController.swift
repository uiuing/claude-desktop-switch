import AppKit
import Darwin
import Foundation
import SwitchCore

/// A process across snapshots: a PID alone can be reused once the process exits.
struct ProcessKey: Hashable { var pid: Int32; var started: UInt64 }
struct ProcessEntry {
    var pid: Int32
    var parent: Int32
    var started: UInt64
    /// The executable, symlinks resolved; empty when it cannot be read.
    var path: String
    var key: ProcessKey { ProcessKey(pid: pid, started: started) }
}

/// Which processes still hold Claude Desktop's files. Claude Code started outside Claude Desktop has its own
/// login and never touches them, so it is not waited for.
enum ProcessTable {
    enum Leftover: Equatable { case code, helper }

    static func snapshot() throws -> [ProcessEntry] {
        let estimate = Int(proc_listallpids(nil, 0))
        guard estimate > 0 else { throw SwitchError.blocked(L10n.tr("Could not confirm that Claude is closed. Close Claude and try again.")) }
        var pids = [pid_t](repeating: 0, count: estimate + 256)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { throw SwitchError.blocked(L10n.tr("Could not confirm that Claude is closed. Close Claude and try again.")) }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(min(count, pids.count)).compactMap { pid in
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            let length = Int(proc_pidpath(pid, &path, UInt32(path.count)))
            return ProcessEntry(pid: pid, parent: Int32(truncatingIfNeeded: info.pbi_ppid),
                                started: info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec,
                                path: length > 0 ? String(decoding: path.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self) : "")
        }
    }

    /// The running Claude Desktop and everything it started. Taken before it quits: its children are re-parented once it exits.
    static func tree(of owners: Set<Int32>, in all: [ProcessEntry]) -> Set<ProcessKey> {
        let parents = Dictionary(all.map { ($0.pid, $0.parent) }, uniquingKeysWith: { a, _ in a })
        func owned(_ pid: Int32) -> Bool {
            var current = pid
            for _ in 0..<64 {
                if owners.contains(current) { return true }
                guard let parent = parents[current], parent > 1 else { return false }
                current = parent
            }
            return false
        }
        return Set(all.filter { owned($0.pid) }.map(\.key))
    }

    /// What keeps a quit Claude from being safe to change: a Claude Code build Claude Desktop installed, a Claude Code
    /// session it started that outlived it, or one of its helpers.
    static func leftover(_ all: [ProcessEntry], codeBuilds: String, tree: Set<ProcessKey>) -> Leftover? {
        if all.contains(where: { isDesktopCode($0, codeBuilds: codeBuilds) || (tree.contains($0.key) && isClaudeCode($0)) }) { return .code }
        // Crashpad only handles crash reports and can finish uploads after its clients exit.
        if all.contains(where: {
            $0.path.contains("/Claude.app/Contents/") &&
                !$0.path.hasSuffix("/Claude.app/Contents/Frameworks/Electron Framework.framework/Helpers/chrome_crashpad_handler")
        }) { return .helper }
        return nil
    }
    static func isDesktopCode(_ entry: ProcessEntry, codeBuilds: String) -> Bool { entry.path.hasPrefix(codeBuilds) }
    /// The native installer runs `claude` from a file named after its version.
    static func isClaudeCode(_ entry: ProcessEntry) -> Bool {
        entry.path.split(separator: "/").last == "claude" || entry.path.contains("/claude/versions/")
    }
}

@MainActor
public final class DesktopController {
    /// Where Claude Desktop installs the Claude Code builds its Code sessions run.
    private let codeBuilds: String
    private var desktopTree: Set<ProcessKey> = []
    public init(environment: MacEnvironment) {
        codeBuilds = environment.desktop.appendingPathComponent("claude-code").resolvingSymlinksInPath().path + "/"
    }
    public var running: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop")
    }
    public var isRunning: Bool { !running.isEmpty }

    public func quitGracefully() async throws -> Bool {
        try BuildAccess.requireClaudeWrites()
        let applications = running
        guard applications.count <= 1 else { throw SwitchError.blocked(L10n.tr("Multiple Claude Desktop instances are running. Close the other instances manually.")) }
        let all = try ProcessTable.snapshot()
        desktopTree = ProcessTable.tree(of: Set(applications.map(\.processIdentifier)), in: all)
        // Sessions Claude Desktop runs end with it; one that already left it would block the change after Claude quit.
        if all.contains(where: { ProcessTable.isDesktopCode($0, codeBuilds: codeBuilds) && !desktopTree.contains($0.key) }) {
            throw SwitchError.blocked(L10n.tr("Claude Code sessions started by Claude Desktop are still running. Wait for them to finish, then try again."))
        }
        for app in applications {
            guard app.terminate() else { throw SwitchError.blocked(L10n.tr("Claude did not accept a normal quit. Finish your current work manually.")) }
        }
        // Claude's own quit cleanup flushes network queues and can take well over ten seconds.
        for _ in 0..<300 {
            if running.isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if !running.isEmpty { throw SwitchError.blocked(L10n.tr("Claude has not fully quit. No data was replaced and no processes will be force-quit.")) }
        try await waitUntilStopped()
        return !applications.isEmpty
    }
    /// Helpers and Code sessions can outlive the main process, or flicker briefly after it exits.
    /// Claude itself running again is never waited out.
    public func waitUntilStopped(seconds: Double = 15) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            do { try assertStopped(); return }
            catch {
                if !running.isEmpty || Date() >= deadline { throw error }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }
    public func assertStopped() throws {
        guard running.isEmpty else { throw SwitchError.blocked(L10n.tr("Claude is running. The operation was stopped.")) }
        switch ProcessTable.leftover(try ProcessTable.snapshot(), codeBuilds: codeBuilds, tree: desktopTree) {
        case .code?: throw SwitchError.blocked(L10n.tr("Claude Code sessions started by Claude Desktop are still running. Wait for them to finish, then try again."))
        case .helper?: throw SwitchError.blocked(L10n.tr("Claude helper processes have not quit. Try again later."))
        case nil: return
        }
    }
    public func launch(_ application: URL) async throws {
        try BuildAccess.requireClaudeWrites()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: application, configuration: config)
    }
}
