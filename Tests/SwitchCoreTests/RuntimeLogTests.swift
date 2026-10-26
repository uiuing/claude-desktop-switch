import Foundation
import XCTest
import SwitchCore
@testable import SwitchStorage

final class RuntimeLogTests: XCTestCase {
    private func root() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/runtime-log-fixtures/\(UUID())")
    }
    private func report(_ log: RuntimeLog) async throws -> RuntimeLog.Report {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RuntimeLog.Report.self, from: await log.export())
    }
    func testConcurrentEventsRotateWithinBoundsAndKeepOperationContext() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let log = RuntimeLog(directory: folder, maximumBytes: 2048, fileCount: 3), operationID = UUID()
        let started = await log.start(version: "1.0.0", build: "1"); XCTAssertTrue(started)
        let successes = await RuntimeLogContext.$operationID.withValue(operationID) {
            await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<100 { group.addTask { await log.record(.failed, component: .operation, level: .error,
                    stage: .preparingConversationPresentation, failure: RuntimeFailure(SwitchError.blocked("synthetic-private-message"))) } }
                var results: [Bool] = []; for await success in group { results.append(success) }; return results
            }
        }
        XCTAssertTrue(successes.allSatisfy { $0 })
        let files = try SafeFiles.strictChildren(folder)
        XCTAssertEqual(files.count, 3)
        for file in files {
            XCTAssertLessThanOrEqual(try SafeFiles.read(file).count, 2048)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let saved = try await report(log)
        XCTAssertFalse(saved.incomplete)
        XCTAssertFalse(saved.events.isEmpty)
        XCTAssertEqual(saved.events.map(\.sequence), saved.events.map(\.sequence).sorted())
        XCTAssertEqual(saved.events.last?.sequence, 101)
        XCTAssertTrue(saved.events.allSatisfy { $0.operationID == operationID })
        XCTAssertEqual(Set(saved.events.map(\.runID)).count, 1)
        let text = String(decoding: try await log.export(), as: UTF8.self)
        XCTAssertFalse(text.contains("synthetic-private-message")); XCTAssertFalse(text.contains(folder.path))
    }
    func testRestartRotatesPartialTailAndRetainsValidPriorEvents() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let first = RuntimeLog(directory: folder)
        _ = await first.start(version: "1.0.0", build: "1")
        _ = await first.record(.failed, component: .app, level: .error, failure: RuntimeFailure(SwitchError.changed))
        let current = folder.appendingPathComponent("runtime.jsonl")
        var original = try SafeFiles.read(current); original += Data("{\"partial\":".utf8)
        try SafeFiles.atomicWrite(original, to: current)
        let second = RuntimeLog(directory: folder)
        let started = await second.start(version: "1.0.0", build: "2"); XCTAssertTrue(started)
        let saved = try await report(second)
        XCTAssertTrue(saved.incomplete)
        XCTAssertTrue(saved.events.contains { $0.event == .failed })
        XCTAssertEqual(Set(saved.events.map(\.runID)).count, 2)
        XCTAssertEqual(saved.events.last?.build, "2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("runtime.1.jsonl").path))
    }
    func testExportDropsForeignFieldsUnknownEventsAndPrivateVersionStrings() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let log = RuntimeLog(directory: folder)
        _ = await log.start(version: "1.0.0", build: "1")
        let current = folder.appendingPathComponent("runtime.jsonl")
        let original = try XCTUnwrap(try SafeFiles.read(current).split(separator: 10).first)
        var entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(original)) as? [String: Any])
        let privateValue = "synthetic-private-value"
        entry["message"] = privateValue; entry["path"] = privateValue; entry["version"] = privateValue
        var data = try JSONSerialization.data(withJSONObject: entry); data.append(10)
        entry["event"] = privateValue
        data += try JSONSerialization.data(withJSONObject: entry); data.append(10)
        try SafeFiles.atomicWrite(data, to: current)
        let output = try await log.export(), saved = try await report(log)
        XCTAssertFalse(String(decoding: output, as: UTF8.self).contains(privateValue))
        XCTAssertTrue(saved.incomplete); XCTAssertEqual(saved.events.count, 1)
        XCTAssertEqual(saved.events[0].version, "unknown")
    }
    func testSymlinkCannotRedirectLogWritesOrExports() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        try SafeFiles.privateDirectory(folder)
        let outside = folder.appendingPathComponent("outside.txt"), contents = Data("synthetic-private-value".utf8)
        try SafeFiles.atomicWrite(contents, to: outside)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("runtime.jsonl"), withDestinationURL: outside)
        let log = RuntimeLog(directory: folder)
        let started = await log.start(version: "1.0.0", build: "1"); XCTAssertFalse(started)
        let saved = try await report(log)
        XCTAssertTrue(saved.incomplete); XCTAssertTrue(saved.events.isEmpty)
        XCTAssertEqual(try SafeFiles.read(outside), contents)
    }
    func testDisabledSinkDoesNotCreateFiles() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let log = RuntimeLog(directory: folder)
        _ = await log.record(.failed, component: .app, level: .error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        do { _ = try await log.export(); XCTFail("Disabled log export must stop") } catch {}
    }
    func testOversizedHistoryDoesNotDisableFutureLogging() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        try SafeFiles.privateDirectory(folder)
        try SafeFiles.atomicWrite(Data(repeating: 65, count: 4096), to: folder.appendingPathComponent("runtime.jsonl"))
        let log = RuntimeLog(directory: folder, maximumBytes: 2048, fileCount: 3)
        let buildID = String(repeating: "a", count: 64)
        let started = await log.start(version: "1.0.0", build: "1", buildID: buildID); XCTAssertTrue(started)
        let saved = try await report(log)
        XCTAssertTrue(saved.incomplete); XCTAssertEqual(saved.events.count, 1)
        XCTAssertEqual(saved.buildID, buildID); XCTAssertEqual(saved.events[0].buildID, buildID)
        for file in try SafeFiles.strictChildren(folder) { XCTAssertLessThanOrEqual(try SafeFiles.read(file).count, 2048) }
    }
}
