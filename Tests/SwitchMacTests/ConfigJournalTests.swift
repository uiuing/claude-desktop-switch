import XCTest
@testable import SwitchMac

final class ConfigJournalTests: XCTestCase {
    private var home: URL!
    private var env: MacEnvironment { MacEnvironment(home: home) }

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/transfer-fixtures/config-journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: env.desktop, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func write(config: String, journal: Data? = nil) throws {
        try Data(config.utf8).write(to: env.desktop.appendingPathComponent("config.json"))
        if let journal { try journal.write(to: env.configJournal) }
    }
    private func journal(_ payload: String, over base: String) -> Data {
        let body = Data(payload.utf8)
        return Data("\(digest(body)) \(digest(Data(base.utf8))) .\n".utf8) + body
    }

    func testNoJournalReadsConfig() throws {
        try write(config: #"{"lastKnownAccountUuid":"a"}"#)
        XCTAssertEqual(try env.effectiveConfig()["lastKnownAccountUuid"].string, "a")
    }

    func testJournalOverCurrentConfigWins() throws {
        let base = #"{"lastKnownAccountUuid":"a","oauth:tokenCache":"old"}"#
        try write(config: base, journal: journal(#"{"lastKnownAccountUuid":"a","oauth:tokenCache":"new"}"#, over: base))
        XCTAssertEqual(try env.effectiveConfig()["oauth:tokenCache"].string, "new")
    }

    func testJournalOverAnotherConfigIsIgnored() throws {
        try write(config: #"{"oauth:tokenCache":"current"}"#,
                  journal: journal(#"{"oauth:tokenCache":"stale"}"#, over: #"{"oauth:tokenCache":"older"}"#))
        XCTAssertEqual(try env.effectiveConfig()["oauth:tokenCache"].string, "current")
    }

    func testTornJournalIsIgnored() throws {
        let base = #"{"oauth:tokenCache":"current"}"#
        var torn = journal(#"{"oauth:tokenCache":"new"}"#, over: base); torn.removeLast(3)
        try write(config: base, journal: torn)
        XCTAssertEqual(try env.effectiveConfig()["oauth:tokenCache"].string, "current")
        XCTAssertThrowsError(try env.liveConfig())
    }

    func testLiveReaderWaitsForCredentialJournalButIgnoresPreferenceChanges() throws {
        let base = #"{"lastKnownAccountUuid":"0a1b2c3d-1111-4aaa-8bbb-000000000001","oauth:tokenCache":"old"}"#
        let pending = base.replacingOccurrences(of: "old", with: "new")
        try write(config: base, journal: journal(pending, over: base))
        XCTAssertThrowsError(try env.liveConfig())
        XCTAssertEqual(try env.effectiveConfig()["oauth:tokenCache"].string, "new")
        try write(config: pending)
        XCTAssertEqual(try env.liveConfig()["oauth:tokenCache"].string, "new")
        let preference = pending.replacingOccurrences(of: "\"oauth:tokenCache\"", with: "\"theme\":\"dark\",\"oauth:tokenCache\"")
        try write(config: pending, journal: journal(preference, over: pending))
        XCTAssertEqual(try env.liveConfig()["oauth:tokenCache"].string, "new")
    }
}
