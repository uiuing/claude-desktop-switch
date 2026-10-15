import XCTest
@testable import SwitchCore

final class UsageResponseParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func parse(_ json: String) throws -> [QuotaWindow] {
        UsageResponseParser.windows(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)), at: now)
    }
    func testUnknownMissingAndInvalidWindowsNeverBecomeZero() throws {
        let windows = try parse(#"{"five_hour":null,"seven_day":{"utilization":101},"seven_day_opus":{"utilization":-1},"other":{"utilization":0},"seven_day_cowork":{"utilization":0}}"#)
        XCTAssertEqual(windows.map(\.id), ["seven_day_cowork"])
        XCTAssertEqual(windows.first?.usedPercent, 0)
    }
    func testScopedWindowsRequireKnownKindAndDeduplicateStableID() throws {
        let windows = try parse(#"{"limits":[{"kind":"weekly_scoped","percent":20,"scope":{"model":{"id":"m1","display_name":"Opus"}}},{"kind":"weekly_scoped","percent":30,"scope":{"model":{"id":"m1","display_name":"Renamed"}}},{"kind":"future_kind","percent":30,"scope":{"model":{"id":"m2","display_name":"Future"}}}]}"#)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.id, "weekly-model:m1")
        XCTAssertEqual(windows.first?.usedPercent, 20)
        XCTAssertEqual(windows.first?.observedAt, now)
        XCTAssertEqual(windows.first?.origin, .live)
    }
    func testMalformedPercentageIsNotCoercedFromString() throws {
        XCTAssertTrue(try parse(#"{"five_hour":{"utilization":"0"},"limits":[{"kind":"weekly_scoped","percent":-3,"scope":{"model":{"display_name":"Opus"}}}]}"#).isEmpty)
    }
    func testMissingResetIsUnknownWhileExplicitNullCanMeanNotStarted() throws {
        let missing = try XCTUnwrap(parse(#"{"five_hour":{"utilization":0}}"#).first)
        let absent = try XCTUnwrap(parse(#"{"five_hour":{"utilization":0,"resets_at":null}}"#).first)
        XCTAssertEqual(missing.resetKnownAbsent, false)
        XCTAssertEqual(absent.resetKnownAbsent, true)
    }
}
