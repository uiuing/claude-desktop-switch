import Foundation
import XCTest
import SwitchCore
import SwitchStorage
@testable import SwitchMac

final class ConversationHistoryTests: XCTestCase {
    private let current = "0a1b2c3d-1111-4aaa-8bbb-000000000001"
    private let previous = "0a1b2c3d-1111-4aaa-8bbb-000000000002"
    private let unrelated = "0a1b2c3d-1111-4aaa-8bbb-000000000003"
    private func project() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/history-fixtures/\(UUID())")
        try SafeFiles.privateDirectory(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func write(_ text: String, at file: URL) throws {
        try SafeFiles.privateDirectory(file.deletingLastPathComponent())
        try SafeFiles.atomicWrite(Data(text.utf8), to: file)
    }

    func testRecordedPriorHistoryResolvesNestedAgentsAndPinsTheirMetadata() throws {
        let project = try project(), history = project.appendingPathComponent(current + ".jsonl")
        let agent = project.appendingPathComponent(previous + "/subagents/agent-fixture.jsonl")
        let child = project.appendingPathComponent(previous + "/subagents/agent-child.jsonl")
        let metadata = agent.deletingPathExtension().appendingPathExtension("meta.json")
        try write(#"{"type":"user","toolUseResult":{"agentId":"fixture"}}"#, at: history)
        try write(#"{"type":"user","toolUseResult":{"agentId":"child"}}"#, at: agent)
        try write(#"{"type":"assistant","message":{"content":"retained result"}}"#, at: child)
        try write(#"{"toolUseId":"fixture-tool"}"#, at: metadata)
        // An unrelated same-ID history must never take part in resolution.
        try write("not-json", at: project.appendingPathComponent(unrelated + "/subagents/agent-fixture.jsonl"))
        let result = try ConversationHistory.dependencies(history, project: project, cli: current, priorSessionIDs: [previous])
        XCTAssertEqual(result.agentHistories, 2)
        XCTAssertEqual(result.historicalAgentHistories, 2)
        XCTAssertEqual(Set(result.files.keys), Set([history, agent, child, metadata].map(\.path)))
        try ConversationResources.validate(.init(files: result.files))
        try write(#"{"toolUseId":"changed-tool"}"#, at: metadata)
        XCTAssertThrowsError(try ConversationResources.validate(.init(files: result.files)))
    }

    func testMissingOrAmbiguousPriorAgentHistoryDoesNotSelectAnArbitraryCopy() throws {
        let project = try project(), history = project.appendingPathComponent(current + ".jsonl")
        try write(#"{"type":"user","toolUseResult":{"agentId":"fixture"}}"#, at: history)
        try write("{}", at: project.appendingPathComponent(previous + "/subagents/agent-fixture.jsonl"))
        XCTAssertThrowsError(try ConversationHistory.dependencies(history, project: project, cli: current, priorSessionIDs: [])) { error in
            XCTAssertEqual((error as? SwitchError)?.localizedDescription,
                L10n.tr("This conversation's subagent history is missing or ambiguous. Nothing was transferred."))
        }
        try write("{}", at: project.appendingPathComponent(unrelated + "/subagents/agent-fixture.jsonl"))
        XCTAssertThrowsError(try ConversationHistory.dependencies(history, project: project, cli: current, priorSessionIDs: [previous, unrelated]))
        try write("{}", at: project.appendingPathComponent(current + "/subagents/agent-fixture.jsonl"))
        let result = try ConversationHistory.dependencies(history, project: project, cli: current, priorSessionIDs: [previous, unrelated])
        XCTAssertEqual(result.agentHistories, 1)
        XCTAssertEqual(result.historicalAgentHistories, 0)
    }

    func testPriorHistoryIdentifiersAndSymlinksRemainValidated() throws {
        XCTAssertEqual(try ConversationHistory.priorSessionIDs(.object([:])), [])
        XCTAssertEqual(try ConversationHistory.priorSessionIDs(.object(["priorCliSessionIds": .array([.string(previous), .string(previous)])])), [previous])
        for value in [JSONValue.string(previous), .array([.null]), .array([.string("../outside")])] {
            XCTAssertThrowsError(try ConversationHistory.priorSessionIDs(.object(["priorCliSessionIds": value])))
        }
        let project = try project(), history = project.appendingPathComponent(current + ".jsonl")
        try write(#"{"type":"user","toolUseResult":{"agentId":"fixture"}}"#, at: history)
        let destination = project.appendingPathComponent(unrelated)
        try write("{}", at: destination.appendingPathComponent("subagents/agent-fixture.jsonl"))
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent(previous), withDestinationURL: destination)
        XCTAssertThrowsError(try ConversationHistory.dependencies(history, project: project, cli: current, priorSessionIDs: [previous]))
    }

    func testSharedHistoryStreamsBeyondTheAttachmentBudgetAndDetectsMutation() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/history-fixtures/\(UUID())")
        try SafeFiles.privateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.jsonl")
        let row = Data((#"{"type":"attachment","payload":""# + String(repeating: "x", count: 128 * 1024) + "\"}\n").utf8)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        for _ in 0..<1025 { try handle.write(contentsOf: row) }
        try handle.write(contentsOf: Data(#"{"type":"user","toolUseResult":{"agentId":"fixture-agent"}}"#.utf8))
        try handle.close()
        let scan = try ConversationHistory.scan(file)
        XCTAssertEqual(scan.agents, ["fixture-agent"])
        XCTAssertEqual(try ConversationHistory.fingerprint(file), .sha256(scan.digest))
        let snapshot = ConversationResources.Retained(files: [file.path: .sha256(scan.digest)])
        try ConversationResources.validate(snapshot)
        try SafeFiles.atomicWrite(Data("{}".utf8), to: file)
        XCTAssertThrowsError(try ConversationResources.validate(snapshot))
    }

    func testStreamingHistoryChecksSyntaxAndNeverTreatsOpaqueMetadataAsAgentReferences() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/history-fixtures/\(UUID())")
        try SafeFiles.privateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.jsonl")
        try SafeFiles.atomicWrite(Data("{}\nnot-json".utf8), to: file)
        XCTAssertThrowsError(try ConversationHistory.scan(file))
        try SafeFiles.atomicWrite(Data(#"{"future":{"agentId":"not-a-native-reference"}}"#.utf8), to: file)
        XCTAssertTrue(try ConversationHistory.scan(file).agents.isEmpty)
    }
}
