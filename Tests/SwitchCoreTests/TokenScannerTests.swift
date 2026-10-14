import Foundation
import XCTest
@testable import SwitchCore
@testable import SwitchStorage

final class TokenScannerTests: XCTestCase {
    private func workspace() throws -> URL {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/activity-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("projects/p"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Taipei")!; return c
    }
    private func line(_ type: String = "assistant", id: String = "same", tokens: Int = 100,
                      date: String = "2026-10-12T16:30:00Z", sidechain: Bool = false, model: String = "opus") -> String {
        """
        {"type":"\(type)","timestamp":"\(date)","isSidechain":\(sidechain),"sessionId":"session","requestId":"request","message":{"id":"\(id)","model":"\(model)","usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":\(tokens),"cache_creation_input_tokens":3}}}
        """ + "\n"
    }
    private func write(_ text: String, to url: URL) throws { try Data(text.utf8).write(to: url) }
    private func append(_ text: String, to url: URL) throws {
        let h = try FileHandle(forWritingTo: url); defer { try? h.close() }
        try h.seekToEnd(); try h.write(contentsOf: Data(text.utf8))
    }
    private func scanner(_ root: URL) -> TokenScanner {
        TokenScanner(projects: root.appendingPathComponent("projects"), cacheURL: root.appendingPathComponent("cache/stats.json"), calendar: calendar,
                     keepsRequestLedger: true, cacheWriteInterval: 0)
    }

    func testClaudeSemanticsAndSeparateLedger() async throws {
        let root = try workspace(), main = root.appendingPathComponent("projects/p/main.jsonl")
        try write(line("user") + line() + line(tokens: 200) + line(sidechain: true) + line(model: "<synthetic>"), to: main)
        // Desktop discovers subagents under non-UUID directories, too.
        let sub = root.appendingPathComponent("projects/p/arbitrary/subagents")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try write(line(tokens: 300, sidechain: true), to: sub.appendingPathComponent("agent-one.jsonl"))
        try write(line(tokens: 9999), to: root.appendingPathComponent("projects/p/main.superseded-old.jsonl"))
        let reader = scanner(root), report = try await reader.scanAnalytics()
        XCTAssertFalse(report.partial); XCTAssertEqual(report.totalFiles, 2)
        XCTAssertEqual(report.sessions, 1); XCTAssertEqual(report.messages, 4)
        XCTAssertEqual(report.activeDays, 1); XCTAssertEqual(report.peakHour, 0)
        XCTAssertEqual(report.totals.total, 618); XCTAssertEqual(report.models.first?.messages, 3)
        let ledger = await reader.ledger()
        XCTAssertEqual(ledger.events.count, 1); XCTAssertEqual(ledger.totals.total, 306)
    }

    func testIncrementalAppendRestartRewriteRemovalAndCacheRecovery() async throws {
        let root = try workspace(), file = root.appendingPathComponent("projects/p/main.jsonl")
        try write(line("user") + line(), to: file)
        let first = scanner(root)
        let initial = try await first.scanAnalytics()
        XCTAssertEqual(initial.totals.total, 106)
        let cache = root.appendingPathComponent("cache/stats.json")
        let stamp = try FileManager.default.attributesOfItem(atPath: cache.path)[.modificationDate] as? Date
        let unchanged = try await first.scanAnalytics()
        XCTAssertEqual(unchanged.messages, 2)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: cache.path)[.modificationDate] as? Date, stamp)
        let restart = scanner(root), cached = await restart.cachedAnalytics()
        XCTAssertEqual(cached?.totals.total, 106)
        try append(line(tokens: 200), to: file)
        let appended = try await restart.scanAnalytics()
        XCTAssertEqual(appended.totals.total, 312); XCTAssertEqual(appended.messages, 3); XCTAssertEqual(appended.sessions, 1)
        // Replacement/truncation invalidates the old contribution.
        try write(line(tokens: 400), to: file)
        let rewritten = try await restart.scanAnalytics()
        XCTAssertEqual(rewritten.totals.total, 406); XCTAssertEqual(rewritten.messages, 1)
        // Same-length in-place edits must also rebuild.
        try write(line(tokens: 500), to: file)
        let equalSize = try await restart.scanAnalytics()
        XCTAssertEqual(equalSize.totals.total, 506)
        try write("", to: file)
        let empty = try await restart.scanAnalytics()
        XCTAssertEqual(empty.totals.total, 0); XCTAssertEqual(empty.messages, 0)
        try FileManager.default.removeItem(at: file)
        let deleted = try await restart.scanAnalytics()
        XCTAssertEqual(deleted.totals.total, 0); XCTAssertEqual(deleted.messages, 0)
        let restored = scanner(root), removed = await restored.cachedAnalytics()
        XCTAssertNil(removed)
        try write("invalid cache", to: cache)
        try write(line(), to: file)
        let repaired = try await scanner(root).scanAnalytics()
        XCTAssertEqual(repaired.totals.total, 106); XCTAssertFalse(repaired.partial)
    }

    func testIncompleteTailAndDateFilter() async throws {
        let root = try workspace(), file = root.appendingPathComponent("projects/p/main.jsonl")
        let later = line(tokens: 200, date: "2026-10-13T16:30:00Z")
        let half = later.index(later.startIndex, offsetBy: later.count / 2)
        try write(line() + String(later[..<half]), to: file)
        let reader = scanner(root), partial = try await reader.scanAnalytics()
        XCTAssertTrue(partial.partial); XCTAssertEqual(partial.totals.total, 106)
        try append(String(later[half...]), to: file)
        let completed = try await reader.scanAnalytics()
        XCTAssertFalse(completed.partial); XCTAssertEqual(completed.totals.total, 312)
        let now = ISO8601DateFormatter().date(from: "2026-10-14T00:00:00Z")!
        XCTAssertEqual(completed.filtered(days: 1, now: now, calendar: calendar).totals.total, 206)
        XCTAssertEqual(completed.filtered(days: 1, now: now, calendar: calendar).sessions, 0)
        XCTAssertEqual(completed.filtered(days: 0, now: now, calendar: calendar).totals.total, 312)
    }

    func testValidUnterminatedTailIsCountedOnceAcrossRestartAndAppend() async throws {
        let root = try workspace(), file = root.appendingPathComponent("projects/p/main.jsonl")
        try write(String(line().dropLast()), to: file)
        let reader = scanner(root), initial = try await reader.scanAnalytics()
        XCTAssertFalse(initial.partial); XCTAssertEqual(initial.totals.total, 106)
        let restart = scanner(root), cached = await restart.cachedAnalytics()
        XCTAssertEqual(cached?.totals.total, 106)
        let unchanged = try await restart.scanAnalytics()
        XCTAssertEqual(unchanged.totals.total, 106)
        try append("\n" + line(tokens: 200), to: file)
        let appended = try await restart.scanAnalytics()
        XCTAssertFalse(appended.partial); XCTAssertEqual(appended.totals.total, 312)
        XCTAssertEqual(appended.sessions, 1); XCTAssertEqual(appended.messages, 2)
    }

    func testCacheSaveFailureRetriesWithoutChangingTranscripts() async throws {
        let root = try workspace(), file = root.appendingPathComponent("projects/p/main.jsonl")
        try write(line(), to: file)
        let directory = root.appendingPathComponent("cache")
        try write("blocks directory creation", to: directory)
        let reader = scanner(root), initial = try await reader.scanAnalytics()
        XCTAssertTrue(initial.cacheWriteFailed); XCTAssertEqual(initial.totals.total, 106)
        try FileManager.default.removeItem(at: directory)
        let retry = try await reader.scanAnalytics()
        XCTAssertFalse(retry.cacheWriteFailed)
        let restored = await scanner(root).cachedAnalytics()
        XCTAssertEqual(restored?.totals.total, 106)
    }

    func testOversizedUnterminatedLineDoesNotBlockFutureRecords() async throws {
        let root = try workspace(), file = root.appendingPathComponent("projects/p/main.jsonl")
        try write(String(repeating: "a", count: 17 * 1024 * 1024), to: file)
        let reader = scanner(root), initial = try await reader.scanAnalytics()
        XCTAssertTrue(initial.partial); XCTAssertEqual(initial.skippedLines, 1)
        try append("\n" + line(), to: file)
        let appended = try await reader.scanAnalytics()
        XCTAssertEqual(appended.skippedLines, 1); XCTAssertEqual(appended.totals.total, 106)
    }

    func testCacheLeavesOutRequestsAndIsRewrittenAtMostOncePerInterval() async throws {
        let root = try workspace(), file = root.appendingPathComponent("projects/p/main.jsonl")
        let cache = root.appendingPathComponent("cache/stats.json")
        func reader() -> TokenScanner { TokenScanner(projects: root.appendingPathComponent("projects"), cacheURL: cache, calendar: calendar) }
        try write(line(), to: file)
        let first = reader()
        _ = try await first.scanAnalytics()
        let written = try Data(contentsOf: cache)
        XCTAssertNil(String(decoding: written, as: UTF8.self).range(of: "ledger"))
        let requests = await first.ledger()
        XCTAssertTrue(requests.events.isEmpty)
        try append(line(id: "next", tokens: 200), to: file)
        let appended = try await first.scanAnalytics()
        XCTAssertEqual(appended.totals.total, 312)
        XCTAssertEqual(try Data(contentsOf: cache), written)
        // A restart from the older cache reads the appended line once.
        let restarted = try await reader().scanAnalytics()
        XCTAssertEqual(restarted.totals.total, 312); XCTAssertEqual(restarted.messages, 2)
    }

    func testAutomaticallyScansBeyondFormerPerFileLimit() async throws {
        let root = try workspace(), file = root.appendingPathComponent("projects/p/large.jsonl")
        // Content is skipped by the typed decoder; the final usage is beyond the old 8 MB cap.
        let padding = "{\"type\":\"attachment\",\"content\":\"" + String(repeating: "a", count: 1024 * 1024) + "\"}\n"
        try write(String(repeating: padding, count: 9) + line(), to: file)
        let reader = scanner(root), report = try await reader.scanAnalytics()
        XCTAssertFalse(report.partial); XCTAssertEqual(report.totals.total, 106)
        XCTAssertEqual(report.processedBytes, report.totalBytes)
        let repeated = try await reader.scanAnalytics()
        XCTAssertEqual(repeated.totals.total, 106)
    }
}
