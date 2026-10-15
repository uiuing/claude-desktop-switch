import XCTest
import SwitchCore
@testable import SwitchStorage

final class LibraryStoreTests: XCTestCase {
    func testMigrationKeepsOnlyServerWindowsAndServerResetTimes() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let id = "0a1b2c3d-1111-4aaa-8bbb-000000000001"
        var server = QuotaWindow(id: "seven_day_opus", title: "Opus", usedPercent: 20, resetsAt: date.addingTimeInterval(3600))
            .attributed(at: date, origin: .live)
        var local = QuotaWindow(id: "five_hour", title: "Session", usedPercent: 40, resetsAt: date.addingTimeInterval(900))
        local.resetIsEstimate = true
        let mixed = UsageSnapshot(accountID: id, observedAt: date.addingTimeInterval(300), origin: .localCache, windows: [local, server])
        let migrated = try XCTUnwrap(mixed.onlineOnly())
        XCTAssertEqual(migrated.windows.map(\.id), ["seven_day_opus"])
        XCTAssertEqual(migrated.observedAt, date)
        XCTAssertEqual(migrated.windows[0].resetsAt, server.resetsAt)
        server.resetOrigin = .localCache
        let withLocalReset = UsageSnapshot(accountID: id, observedAt: date, origin: .live, windows: [server])
        XCTAssertNil(withLocalReset.onlineOnly()?.windows[0].resetsAt)
        XCTAssertNil(UsageSnapshot(accountID: id, observedAt: date, origin: .localCache, windows: [local]).onlineOnly())

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/library-tests/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        var state = LibraryState()
        state.usage[id] = mixed; state.usageHistory[id] = [mixed]
        try await store.save(state)
        let loaded = try await store.load()
        XCTAssertEqual(loaded.usage[id], migrated)
        XCTAssertEqual(loaded.usageHistory[id], [migrated])
    }
    func testLegacyCookieBasedInvalidFlagDoesNotPermanentlyBlockSavedLogin() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/library-tests/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var state = LibraryState()
        var account = Account(id: "0a1b2c3d-1111-4aaa-8bbb-000000000001", hasSnapshot: true, snapshotFingerprint: "synthetic-fingerprint")
        account.loginInvalidAt = Date(timeIntervalSince1970: 1_800_000_000)
        state.accounts = [account]
        let store = LibraryStore(root: root)
        try await store.save(state)
        let before = try Data(contentsOf: root.appendingPathComponent("library.json"))
        let loaded = try await store.load()
        XCTAssertNil(loaded.accounts.first?.loginInvalidAt)
        XCTAssertEqual(loaded.accounts.first?.hasSnapshot, true)
        XCTAssertEqual(loaded.accounts.first?.snapshotFingerprint, "synthetic-fingerprint")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), before)
    }
}
