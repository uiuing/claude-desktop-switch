import XCTest
import SwitchCore
@testable import SwitchMac
@testable import SwitchStorage

final class CodeTaskSourceTests: XCTestCase {
    private final class FixtureSystem: @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        private var started: UInt64 = 10
        private var ownerReads = 0
        private var probeCount = 0
        private var onRead: (@Sendable (Int) -> Void)?
        var probes: Int { lock.lock(); defer { lock.unlock() }; return probeCount }
        func recordProbe() { lock.lock(); defer { lock.unlock() }; probeCount += 1 }
        func setRunning(_ value: Bool) { lock.lock(); defer { lock.unlock() }; running = value }
        func restart() { lock.lock(); defer { lock.unlock() }; started += 1 }
        func onOwnerRead(_ action: @escaping @Sendable (Int) -> Void) { lock.lock(); defer { lock.unlock() }; onRead = action }
        func owners() -> [Int32] {
            lock.lock()
            ownerReads += 1
            let count = ownerReads, action = onRead, result: [Int32] = running ? [10] : []
            lock.unlock()
            action?(count)
            return result
        }
        func processes() -> [ProcessEntry] {
            lock.lock(); defer { lock.unlock() }
            return [ProcessEntry(pid: 10, parent: 1, started: started, path: "/fixture/Desktop")]
        }
    }
    private let account = "0a1b2c3d-1111-4aaa-8bbb-000000000001"
    private let organization = "0a1b2c3d-1111-4aaa-8bbb-000000000002"
    private func fixture() throws -> MacEnvironment {
        let home = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/transfer-fixtures/task-source-" + UUID().uuidString)
        let environment = MacEnvironment(home: home)
        try FileManager.default.createDirectory(at: environment.desktop, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": account])
            .write(to: environment.desktop.appendingPathComponent("config.json"))
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return environment
    }
    private func source(_ environment: MacEnvironment, _ system: FixtureSystem) -> CodeTaskSource {
        CodeTaskSource(environment: environment, runningApplications: { system.owners() }, processSnapshot: { system.processes() },
            loginProbe: LoginProbe.Cache { _, _ in system.recordProbe(); return .init(signedIn: true) })
    }

    func testOnlyDesktopOwnedRootEnginesAreCandidates() {
        let processes = [
            ProcessEntry(pid: 10, parent: 1, started: 10, path: "/Applications/Claude.app/Contents/MacOS/Claude"),
            ProcessEntry(pid: 11, parent: 10, started: 11, path: "/fixture/claude-code/build/claude"),
            ProcessEntry(pid: 12, parent: 11, started: 12, path: "/fixture/claude-code/build/claude"),
            ProcessEntry(pid: 13, parent: 1, started: 13, path: "/fixture/claude-code/build/claude"),
            ProcessEntry(pid: 14, parent: 1, started: 14, path: "/fixture/claude/versions/version"),
            ProcessEntry(pid: 15, parent: 10, started: 15, path: "/Applications/Claude.app/Contents/Frameworks/Helper"),
            ProcessEntry(pid: 16, parent: 15, started: 16, path: "/fixture/claude/versions/version")
        ]
        let result = CodeTaskSource.codeProcesses(processes, owners: [10], codeBuilds: "/fixture/claude-code/")
        XCTAssertEqual(result, [CodeTaskProcess(pid: 11, started: 11), CodeTaskProcess(pid: 16, started: 16)])
    }

    func testPollingReusesLoginEvidenceButKeepsBothContextChecks() async throws {
        let environment = try fixture(), system = FixtureSystem()
        let source = source(environment, system)
        let scope = try XCTUnwrap(CodeTaskScope(accountID: account, organizationID: organization))
        for _ in 0..<10 {
            let result = await source.scan(scope: scope, followed: [])
            XCTAssertEqual(result.availability, .ready)
        }
        XCTAssertEqual(system.probes, 1)
        system.restart()
        let restarted = await source.scan(scope: scope, followed: [])
        XCTAssertEqual(restarted.availability, .ready); XCTAssertEqual(system.probes, 2)
        let other = try XCTUnwrap(CodeTaskScope(accountID: account, organizationID: "0a1b2c3d-1111-4aaa-8bbb-000000000003"))
        let changed = await source.scan(scope: other, followed: [])
        XCTAssertEqual(changed.availability, .ready); XCTAssertEqual(system.probes, 3)
        system.setRunning(false)
        let offline = await source.scan(scope: other, followed: [])
        XCTAssertEqual(offline.availability, .offline)
        system.setRunning(true)
        let resumed = await source.scan(scope: other, followed: [])
        XCTAssertEqual(resumed.availability, .ready); XCTAssertEqual(system.probes, 4)
    }

    func testAccountChangesBetweenContextsRejectCachedLoginEvidence() async throws {
        let environment = try fixture(), system = FixtureSystem()
        let other = "0a1b2c3d-1111-4aaa-8bbb-000000000004"
        let config = try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": other])
        system.onOwnerRead { count in
            if count == 2 { try? config.write(to: environment.desktop.appendingPathComponent("config.json"), options: .atomic) }
        }
        let source = source(environment, system)
        let result = await source.scan(scope: try XCTUnwrap(CodeTaskScope(accountID: account, organizationID: organization)), followed: [])
        XCTAssertEqual(result.availability, .unavailable)
        let next = await source.scan(scope: try XCTUnwrap(CodeTaskScope(accountID: other, organizationID: organization)), followed: [])
        XCTAssertEqual(next.availability, .ready); XCTAssertEqual(system.probes, 2)
    }

    func testDesktopRestartBetweenContextsRejectsTheSnapshot() async throws {
        let environment = try fixture(), system = FixtureSystem()
        system.onOwnerRead { [weak system] count in if count == 2 { system?.restart() } }
        let source = source(environment, system)
        let result = await source.scan(scope: try XCTUnwrap(CodeTaskScope(accountID: account, organizationID: organization)), followed: [])
        XCTAssertEqual(result.availability, .connecting)
        XCTAssertEqual(system.probes, 2)
    }
}
