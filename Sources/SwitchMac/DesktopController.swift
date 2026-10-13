import AppKit
import Foundation
import SwitchCore

@MainActor
public final class DesktopController {
    public init() {}
    public var running: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop")
    }
    public var isRunning: Bool { !running.isEmpty }

    private struct ProcessEntry { var pid: Int32; var parent: Int32; var command: String }
    private func processes() throws -> [ProcessEntry] {
        let task = Process(); let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,ppid=,comm="]
        task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw SwitchError.blocked(L10n.tr("Could not verify Claude's worker processes. Stopped.")) }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { return nil }
            return ProcessEntry(pid: pid, parent: parent, command: String(fields[2]))
        }
    }
    private func isCLI(_ entry: ProcessEntry) -> Bool {
        entry.command.trimmingCharacters(in: .whitespaces).split(separator: "/").last == "claude"
    }

    /// Refuse external CLI work; there is no safe way to transfer an in-flight provider request.
    /// Code sessions owned by Claude Desktop end with it, so they do not block a graceful quit.
    public func assertNoCLI(allowingChildrenOf owners: Set<Int32> = []) throws {
        let all = try processes()
        let parents = Dictionary(all.map { ($0.pid, $0.parent) }, uniquingKeysWith: { a, _ in a })
        func owned(_ pid: Int32) -> Bool {
            var current = pid
            for _ in 0..<64 {
                guard let parent = parents[current], parent > 1 else { return false }
                if owners.contains(parent) { return true }
                current = parent
            }
            return false
        }
        if all.contains(where: { isCLI($0) && !owned($0.pid) }) {
            throw SwitchError.blocked(L10n.tr("Claude Code workers were detected. Finish your work before switching or migrating."))
        }
    }

    public func quitGracefully() async throws -> Bool {
        try BuildAccess.requireClaudeWrites()
        let applications = running
        guard applications.count <= 1 else { throw SwitchError.blocked(L10n.tr("Multiple Claude Desktop instances are running. Close the other instances manually.")) }
        try assertNoCLI(allowingChildrenOf: Set(applications.map(\.processIdentifier)))
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
        let all = try processes()
        if all.contains(where: isCLI) {
            throw SwitchError.blocked(L10n.tr("Claude Code workers were detected. Finish your work before switching or migrating."))
        }
        guard !all.contains(where: { $0.command.contains("/Claude.app/Contents/") }) else {
            throw SwitchError.blocked(L10n.tr("Claude helper processes have not quit. Try again later."))
        }
    }
    public func launch(_ application: URL) async throws {
        try BuildAccess.requireClaudeWrites()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: application, configuration: config)
    }
}
