import Foundation
import XCTest
@testable import SwitchStorage

final class LevelDBSnapshotTests: XCTestCase {
    func testRoundTripFragmentsEmptyValuesAndBinaryKeys() throws {
        let values: [Data: Data] = [Data([0, 255]): Data(), Data("long".utf8): Data(repeating: 17, count: 100_000)]
        XCTAssertEqual(try LevelDBSnapshot.read(LevelDBSnapshot.files(values)), values)
        XCTAssertEqual(try LevelDBSnapshot.read(LevelDBSnapshot.files([:])), [:])
    }
    func testChecksumsTruncationUnknownManifestAndConflictingSequenceFailClosed() throws {
        var files = try LevelDBSnapshot.files([Data([1]): Data([2])])
        files["000003.log"]![8] ^= 1
        XCTAssertThrowsError(try LevelDBSnapshot.read(files))
        files = try LevelDBSnapshot.files([Data([1]): Data(repeating: 3, count: 40_000)])
        files["000003.log"]!.removeLast()
        XCTAssertThrowsError(try LevelDBSnapshot.read(files))
        files = try LevelDBSnapshot.files([:]); files["MANIFEST-000001"] = LevelDBSnapshot.logRecord(Data([100]))
        XCTAssertThrowsError(try LevelDBSnapshot.read(files))
        files = try LevelDBSnapshot.files([Data([1]): Data([2])])
        files["000004.log"] = try LevelDBSnapshot.files([Data([1]): Data([3])])["000003.log"]
        XCTAssertThrowsError(try LevelDBSnapshot.read(files))
    }
    func testLatestWALDeleteDoesNotResurrectValue() throws {
        let key = Data("deleted".utf8)
        var files = try LevelDBSnapshot.files([key: Data([1])])
        let deletion = LevelDBSnapshot.fixed(2, 8) + LevelDBSnapshot.fixed(1, 4) + Data([0]) + LevelDBSnapshot.bytes(key)
        files["000004.log"] = LevelDBSnapshot.logRecord(deletion)
        XCTAssertEqual(try LevelDBSnapshot.read(files), [:])
    }
    func testMissingActiveLogStopsInsteadOfAcceptingPartialHistory() throws {
        var files = try LevelDBSnapshot.files([Data([1]): Data([2])])
        files.removeValue(forKey: "000003.log")
        XCTAssertThrowsError(try LevelDBSnapshot.read(files))
        files = try LevelDBSnapshot.files([Data([1]): Data([2])])
        files["000002.ldb"] = Data("obsolete table outside manifest".utf8)
        XCTAssertEqual(try LevelDBSnapshot.read(files), [Data([1]): Data([2])])
    }
    /// Opt-in interoperability check. Only the synthetic profile under .build is accepted.
    func testNativeChromiumFixture() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAUDE_SWITCH_CHROMIUM_FIXTURE"] == "1")
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/chromium-continuity-fixture/Default/Local Storage/leveldb")
        var files: [String: Data] = [:]
        for file in try SafeFiles.strictChildren(folder) { files[file.lastPathComponent] = try SafeFiles.read(file, limit: 128 * 1024 * 1024) }
        var values = try LevelDBSnapshot.read(files)
        let prefix = Data("_http://127.0.0.1:18763\0".utf8)
        XCTAssertEqual(values[prefix + Data([1]) + Data("synthetic-target-auth".utf8)], Data([1]) + Data("target-only".utf8))
        XCTAssertNil(values[prefix + Data([1]) + Data("fixture-deleted".utf8)])
        values[prefix + Data([1]) + Data("fixture-merged".utf8)] = Data([0]) + "\u{6d4b}\u{8bd5}\u{1f680}".data(using: .utf16LittleEndian)!
        let rebuilt = try LevelDBSnapshot.files(values)
        XCTAssertEqual(try LevelDBSnapshot.read(rebuilt), values)
        let saved = folder.deletingLastPathComponent().appendingPathComponent("original-fixture-" + UUID().uuidString)
        try FileManager.default.moveItem(at: folder, to: saved)
        try SafeFiles.privateDirectory(folder)
        for (name, data) in rebuilt { try SafeFiles.atomicWrite(data, to: folder.appendingPathComponent(name)) }
    }
}
