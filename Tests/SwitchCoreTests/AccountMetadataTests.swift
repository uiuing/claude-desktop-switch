import XCTest
import SwitchCore

final class AccountMetadataTests: XCTestCase {
    private let accountID = "0a1b2c3d-1111-4aaa-8bbb-000000000001"
    private let organization = "0a1b2c3d-3333-4aaa-8bbb-000000000003"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testLocalEmailUpdatesUntilTheServerConfirmsIt() throws {
        var account = Account(id: accountID)
        XCTAssertTrue(account.observeEmail("mi•••el@gmail.com"))
        XCTAssertTrue(account.observeEmail("al•••ce@outlook.com"))
        XCTAssertTrue(account.observeEmail("sa•••ra@gmail.com", verifiedAt: now))
        account = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(account))
        XCTAssertFalse(account.observeEmail("mi•••el@gmail.com"))
        XCTAssertFalse(account.observeEmail("mi•••el@gmail.com", verifiedAt: now.addingTimeInterval(-1)))
        XCTAssertEqual(account.email, "sa•••ra@gmail.com")
        XCTAssertEqual(account.emailVerifiedAt, now)
        XCTAssertTrue(account.observeEmail("al•••ce@outlook.com", verifiedAt: now.addingTimeInterval(1)))
    }

    func testFallbackEmailOnlyFillsMissingInformation() {
        var account = Account(id: accountID)
        XCTAssertTrue(account.observeEmail("mi•••el@gmail.com", fillOnly: true))
        XCTAssertFalse(account.observeEmail("al•••ce@outlook.com", fillOnly: true))
        XCTAssertFalse(account.observeEmail(nil, verifiedAt: now))
        XCTAssertEqual(account.email, "mi•••el@gmail.com")
        XCTAssertNil(account.emailVerifiedAt)
    }

    func testLocalPlanChangesAndUnknownStayBelowOnlineAuthority() {
        var account = Account(id: accountID, organizationID: organization)
        XCTAssertTrue(account.observePlan("Max 20x", organizationID: organization, at: now))
        XCTAssertFalse(account.observePlan("Max 20x", organizationID: organization, at: now.addingTimeInterval(1)))
        XCTAssertEqual(account.planObservedAt, now)
        XCTAssertTrue(account.observePlan("Free", organizationID: organization, at: now.addingTimeInterval(2)))
        XCTAssertTrue(account.observePlan(nil, organizationID: organization, at: now.addingTimeInterval(3)))
        XCTAssertTrue(account.observePlan("Pro", organizationID: organization, at: now, verified: true))
        XCTAssertFalse(account.observePlan("Max 20x", organizationID: organization, at: now.addingTimeInterval(4)))
        XCTAssertEqual(account.plan, "Pro")
        XCTAssertTrue(account.observePlan(nil, organizationID: organization, at: now.addingTimeInterval(1), verified: true))
        XCTAssertFalse(account.observePlan("Free", organizationID: organization, at: now.addingTimeInterval(5)))
        XCTAssertNil(account.plan)
    }

    func testLegacyEmailStillLoadsWithoutInventingOnlineConfirmation() throws {
        let json = #"{"id":"0a1b2c3d-1111-4aaa-8bbb-000000000001","hasSnapshot":true,"email":"mi•••el@gmail.com"}"#
        let account = try JSONDecoder().decode(Account.self, from: Data(json.utf8))
        XCTAssertEqual(account.email, "mi•••el@gmail.com")
        XCTAssertNil(account.emailVerifiedAt)
    }
}
