import XCTest
@testable import SwitchMac

final class ProcessTableTests: XCTestCase {
    private let builds = "/Users/fixture/Library/Application Support/Claude/claude-code/"
    private let helperPath = "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"
    private let nativeCLI = "/Users/fixture/.local/share/claude/versions/2.0.1"
    private func entry(_ pid: Int32, parent: Int32, path: String, started: UInt64 = 1) -> ProcessEntry {
        ProcessEntry(pid: pid, parent: parent, started: started, path: path)
    }

    func testTreeHoldsClaudeDesktopAndWhatItStartedOnly() {
        let all = [entry(100, parent: 1, path: "/Applications/Claude.app/Contents/MacOS/Claude"),
                   entry(101, parent: 100, path: helperPath),
                   entry(102, parent: 101, path: builds + "2.0.1/claude"),
                   entry(200, parent: 1, path: nativeCLI),
                   entry(201, parent: 200, path: "/opt/homebrew/bin/node")]
        XCTAssertEqual(ProcessTable.tree(of: [100], in: all), Set([100, 101, 102].map { ProcessKey(pid: $0, started: 1) }))
    }

    func testClaudeCodeStartedOutsideClaudeDesktopDoesNotBlock() {
        let terminal = [entry(200, parent: 1, path: nativeCLI), entry(201, parent: 1, path: "/opt/homebrew/bin/node")]
        XCTAssertNil(ProcessTable.leftover(terminal, codeBuilds: builds, tree: []))
    }

    func testClaudeDesktopSessionsAndHelpersBlock() {
        XCTAssertEqual(ProcessTable.leftover([entry(102, parent: 1, path: builds + "2.0.1/claude")], codeBuilds: builds, tree: []), .code)
        // Started by Claude Desktop from another installation, then re-parented when Claude quit.
        let started = entry(103, parent: 1, path: nativeCLI, started: 7)
        XCTAssertEqual(ProcessTable.leftover([started], codeBuilds: builds, tree: [started.key]), .code)
        // The same PID reused by a later process is a different process.
        XCTAssertNil(ProcessTable.leftover([entry(103, parent: 1, path: nativeCLI, started: 8)], codeBuilds: builds, tree: [started.key]))
        // An MCP server Claude Desktop started is not Claude Code.
        let server = entry(104, parent: 1, path: "/opt/homebrew/bin/node", started: 9)
        XCTAssertNil(ProcessTable.leftover([server], codeBuilds: builds, tree: [server.key]))
        XCTAssertEqual(ProcessTable.leftover([entry(105, parent: 1, path: helperPath)], codeBuilds: builds, tree: []), .helper)
    }

    func testSnapshotListsThisProcessWithItsExecutable() throws {
        let current = try ProcessTable.snapshot().first { $0.pid == ProcessInfo.processInfo.processIdentifier }
        XCTAssertNotNil(current)
        XCTAssertFalse(current?.path.isEmpty ?? true)
    }
}
