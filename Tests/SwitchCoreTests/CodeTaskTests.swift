import XCTest
import SwitchCore
@testable import SwitchStorage

final class CodeTaskTests: XCTestCase {
    private let account = "0a1b2c3d-1111-4aaa-8bbb-000000000001"
    private let other = "1a1b2c3d-2222-4aaa-8bbb-000000000002"
    private let org = "2a1b2c3d-3333-4aaa-8bbb-000000000003"
    private let cli = "3a1b2c3d-4444-4aaa-8bbb-000000000004"
    private let host = "local_4a1b2c3d-5555-4aaa-8bbb-000000000005"
    private let process = CodeTaskProcess(pid: 123, started: 1_800_000_000_123_456)
    private var scope: CodeTaskScope { CodeTaskScope(accountID: account, organizationID: org)! }
    private func session(owner: String? = nil) -> Conversation {
        let owner = owner ?? account
        return .init(id: owner + "/" + org + "/code/" + host, sessionID: host, accountID: owner,
                     organizationID: org, title: "Fixture title", kind: .code, modifiedAt: .distantPast,
                     project: "/fixture/project", recordRelativePath: "fixture", cliSessionID: cli)
    }
    private func fixture() throws -> (URL, CodeTaskReader) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/code-task-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, CodeTaskReader(desktop: root.appendingPathComponent("desktop"), registry: root.appendingPathComponent("registry")))
    }
    private func write(_ value: [String: Any], _ path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value).write(to: path)
    }
    private func index(_ root: URL, owner: String? = nil, title: String = "Fixture title") throws -> URL {
        let path = root.appendingPathComponent("desktop/claude-code-sessions/" + (owner ?? account) + "/" + org + "/" + host + ".json")
        try write(["sessionId": host, "cliSessionId": cli, "title": title, "cwd": "/fixture/project", "lastActivityAt": 1], path)
        return path
    }
    private func record(status: String = "busy", waiting: String = "permission prompt") -> [String: Any] {
        ["pid": 123, "sessionId": cli, "hostSessionId": host, "procStart": "Fri Jan 15 08:00:00 2027",
         "startedAt": 1_800_000_000_500, "kind": "interactive", "entrypoint": "claude-desktop",
         "status": status, "waitingFor": waiting, "updatedAt": 1, "statusUpdatedAt": 1]
    }
    func testExplicitStatesIgnoreActivityTimestampsAndUseDesktopTitle() async throws {
        let (root, reader) = try fixture()
        _ = try index(root)
        for (raw, waiting, expected) in [("busy", "", CodeTaskStatus.running), ("shell", "", .running),
            ("waiting", "permission prompt", .permission), ("waiting", "input needed", .input),
            ("waiting", "sandbox request", .waiting), ("waiting", "new reason", .waiting), ("idle", "", .idle)] {
            var value = record(status: raw, waiting: waiting)
            value["name"] = "Registry name is not the Desktop title"
            try write(value, root.appendingPathComponent("registry/123.json"))
            let result = await reader.scan(scope: scope, processes: [process], followed: [])
            XCTAssertEqual(result.availability, .ready, raw)
            XCTAssertEqual(result.tasks.first?.status, expected, raw)
            XCTAssertEqual(result.tasks.first?.conversation.title, "Fixture title")
        }
        _ = try index(root, title: "Renamed title")
        let renamed = await reader.scan(scope: scope, processes: [process], followed: [])
        XCTAssertEqual(renamed.tasks.first?.conversation.title, "Renamed title")
        XCTAssertEqual(renamed.running, 0)
    }
    func testMissingMalformedUnknownAndReusedPIDNeverBecomeZero() async throws {
        let (root, reader) = try fixture()
        _ = try index(root)
        let file = root.appendingPathComponent("registry/123.json")
        let missing = await reader.scan(scope: scope, processes: [process], followed: [session()])
        XCTAssertNil(missing.running); XCTAssertEqual(missing.tasks.first?.status, .unknown)
        for key in ["status", "procStart", "hostSessionId", "sessionId", "pid", "startedAt", "kind"] {
            var value = record(); value[key] = "unsupported"
            try write(value, file)
            let result = await reader.scan(scope: scope, processes: [process], followed: [session()])
            XCTAssertNil(result.running, key); XCTAssertFalse(result.tasks.contains { $0.status == .running }, key)
        }
        try Data("{\"pid\":".utf8).write(to: file)
        let torn = await reader.scan(scope: scope, processes: [process], followed: [])
        XCTAssertEqual(torn.availability, .incomplete)
        try write(record(), file)
        let reused = await reader.scan(scope: scope, processes: [.init(pid: 123, started: process.started + 1_000_000)], followed: [])
        XCTAssertNil(reused.running); XCTAssertTrue(reused.tasks.isEmpty)
        let sameSecond = await reader.scan(scope: scope, processes: [.init(pid: 123, started: process.started + 500_000)], followed: [])
        XCTAssertNil(sameSecond.running)
    }
    func testExitedProcessCoworkTerminalAndSpareDoNotCount() async throws {
        let (root, reader) = try fixture()
        _ = try index(root)
        try write(record(), root.appendingPathComponent("registry/123.json"))
        let gone = await reader.scan(scope: scope, processes: [], followed: [session()])
        XCTAssertEqual(gone.running, 0); XCTAssertEqual(gone.tasks.first?.status, .notRunning)
        for entrypoint in ["cli", "local-agent", "claude-vscode"] {
            var value = record(); value["entrypoint"] = entrypoint
            try write(value, root.appendingPathComponent("registry/123.json"))
            let result = await reader.scan(scope: scope, processes: [process], followed: [])
            XCTAssertEqual(result.running, 0); XCTAssertTrue(result.tasks.isEmpty)
        }
        var spare = record(); spare["spare"] = true; spare.removeValue(forKey: "hostSessionId")
        try write(spare, root.appendingPathComponent("registry/123.json"))
        let result = await reader.scan(scope: scope, processes: [process], followed: [])
        XCTAssertEqual(result.running, 0)
    }
    func testCurrentAccountIndexAndHostIDRequiredEvenForSharedCLI() async throws {
        let (root, reader) = try fixture()
        _ = try index(root, owner: other)
        try write(record(), root.appendingPathComponent("registry/123.json"))
        let absent = await reader.scan(scope: scope, processes: [process], followed: [session(owner: other)])
        XCTAssertTrue(absent.tasks.isEmpty); XCTAssertNil(absent.running)
        let path = try index(root)
        try write(["sessionId": host, "cliSessionId": UUID().uuidString, "title": "Different CLI"], path)
        let mismatched = await reader.scan(scope: scope, processes: [process], followed: [])
        XCTAssertNil(mismatched.running); XCTAssertTrue(mismatched.tasks.isEmpty)
    }
    func testSymlinkOversizeAndDuplicateRecordsFailClosed() async throws {
        let (root, reader) = try fixture()
        let target = try index(root)
        let file = root.appendingPathComponent("registry/123.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let linked = await reader.scan(scope: scope, processes: [process], followed: [])
        XCTAssertNil(linked.running)
        try FileManager.default.removeItem(at: file)
        try Data(repeating: 32, count: 65 * 1024).write(to: file)
        let oversized = await reader.scan(scope: scope, processes: [process], followed: [])
        XCTAssertNil(oversized.running)
        try write(record(), file)
        var duplicate = record(); duplicate["pid"] = 124
        try write(duplicate, root.appendingPathComponent("registry/124.json"))
        let result = await reader.scan(scope: scope, processes: [process, .init(pid: 124, started: process.started)], followed: [])
        XCTAssertNil(result.running); XCTAssertEqual(result.tasks.count, 1); XCTAssertEqual(result.tasks.first?.status, .unknown)
    }
    func testSwitchInvalidatesLateResultsAndReusedInstancesIncludingRollback() throws {
        var binding = CodeTaskBinding()
        let task = CodeTask(conversation: session(), status: .running, process: process)
        let a = binding.begin(scope)
        let result = CodeTaskSnapshot(scope: scope, availability: .ready, tasks: [task], processes: [process])
        XCTAssertTrue(binding.accept(result, for: a))
        binding.invalidate(.connecting)
        binding.invalidate(.switching, excludeProcesses: true)
        XCTAssertNil(binding.snapshot.running); XCTAssertTrue(binding.snapshot.tasks.isEmpty)
        XCTAssertFalse(binding.accept(result, for: a))
        let bScope = CodeTaskScope(accountID: other, organizationID: org)!
        let b = binding.begin(bScope)
        var copied = task; copied.conversation = session(owner: other)
        XCTAssertTrue(binding.accept(.init(scope: bScope, availability: .ready, tasks: [copied], processes: [process]), for: b))
        XCTAssertEqual(binding.snapshot.tasks.first?.status, .unknown); XCTAssertNil(binding.snapshot.running)
        binding.invalidate(.switching, excludeProcesses: true)
        let rollback = binding.begin(scope)
        XCTAssertFalse(binding.accept(result, for: a)); XCTAssertFalse(binding.accept(.init(scope: bScope, availability: .ready), for: b))
        var fresh = task; fresh.status = .idle; fresh.process = .init(pid: 123, started: process.started + 5_000_000)
        XCTAssertTrue(binding.accept(.init(scope: scope, availability: .ready, tasks: [fresh], processes: [fresh.process!]), for: rollback))
        XCTAssertEqual(binding.snapshot.running, 0); XCTAssertEqual(binding.snapshot.tasks.first?.status, .idle)
    }
    func testFollowedIdlePinsAboveWaitingAndNavigationNeverCarriesAPrompt() throws {
        let idle = CodeTask(conversation: session(), status: .idle)
        var waiting = idle; waiting.conversation.id = "second"; waiting.conversation.sessionID = "local_5a1b2c3d-5555-4aaa-8bbb-000000000006"; waiting.status = .input
        let snapshot = CodeTaskSnapshot(scope: scope, availability: .ready, tasks: [waiting, idle])
        let follows = [FollowRule(conversationID: idle.id, sessionID: host)]
        XCTAssertEqual(snapshot.ordered(follows: follows).first?.id, idle.id)
        XCTAssertEqual(snapshot.waiting, 1)
        XCTAssertEqual(idle.destination?.absoluteString, "claude://claude.ai/epitaxy/" + host)
        XCTAssertNil(URLComponents(url: try XCTUnwrap(idle.destination), resolvingAgainstBaseURL: false)?.query)
        var unsafe = idle; unsafe.conversation.sessionID = "../new?q=execute"
        XCTAssertNil(unsafe.destination)
        unsafe = idle; unsafe.conversation.kind = .cowork; XCTAssertNil(unsafe.destination)
        unsafe = idle; unsafe.conversation.archived = true; XCTAssertNil(unsafe.destination)
        let preferences = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        XCTAssertTrue(preferences.showCodeTasks)
    }
    func testAmbiguousOrganizationAndArchiveCannotBeAttributed() async throws {
        let (root, reader) = try fixture()
        let original = try index(root)
        try write(record(), root.appendingPathComponent("registry/123.json"))
        let duplicate = root.appendingPathComponent("desktop/claude-code-sessions/" + account + "/5a1b2c3d-5555-4aaa-8bbb-000000000006/" + host + ".json")
        try FileManager.default.createDirectory(at: duplicate.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: original, to: duplicate)
        let ambiguous = await reader.scan(scope: scope, processes: [process], followed: [session()])
        XCTAssertNil(ambiguous.running); XCTAssertTrue(ambiguous.tasks.isEmpty)
        try FileManager.default.removeItem(at: duplicate)
        try write(["sessionId": host, "cliSessionId": cli, "isArchived": true], original)
        let archived = await reader.scan(scope: scope, processes: [process], followed: [session()])
        XCTAssertNil(archived.running); XCTAssertTrue(archived.tasks.isEmpty)
    }
    func testTransientReadFailureDoesNotForgetExcludedProcessAndEpoch() {
        var binding = CodeTaskBinding()
        let a = binding.begin(scope)
        let task = CodeTask(conversation: session(), status: .running, process: process)
        let result = CodeTaskSnapshot(scope: scope, availability: .ready, tasks: [task], processes: [process])
        XCTAssertTrue(binding.accept(result, for: a))
        binding.invalidate(.switching, excludeProcesses: true)
        let rollback = binding.begin(scope)
        XCTAssertTrue(binding.accept(.init(scope: scope, availability: .connecting), for: rollback))
        XCTAssertTrue(binding.excludedProcesses.contains(process))
        XCTAssertTrue(binding.accept(result, for: rollback))
        XCTAssertNil(binding.snapshot.running)
        binding.invalidate(.unavailable)
        XCTAssertFalse(binding.accept(result, for: rollback))
    }
}
