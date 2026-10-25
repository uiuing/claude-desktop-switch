import Foundation
import XCTest
import SwitchStorage
@testable import SwitchMac

final class ConversationHistoryTests: XCTestCase {
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
