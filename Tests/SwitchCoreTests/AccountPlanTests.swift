import XCTest
import SwitchCore
@testable import SwitchStorage

final class AccountPlanTests: XCTestCase {
    private let organization = "0a1b2c3d-3333-4aaa-8bbb-000000000003"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFreeRequiresPositiveEvidence() {
        XCTAssertNil(AccountPlan.resolve(tier: nil))
        XCTAssertNil(AccountPlan.resolve(tier: nil, hasMax: false, hasPro: false))
        XCTAssertNil(AccountPlan.resolve(tier: "future_tier", capabilities: ["chat"]))
        XCTAssertNil(AccountPlan.resolve(tier: nil, capabilities: ["chat", "api"]))
        XCTAssertNil(AccountPlan.resolve(tier: nil, capabilities: ["chat", "raven"]))
        XCTAssertNil(AccountPlan.resolve(tier: "default_claude_ai", capabilities: ["chat", "claude_future"]))
        XCTAssertEqual(AccountPlan.resolve(tier: "default_claude_ai"), "Free")
        XCTAssertEqual(AccountPlan.resolve(tier: "claude_free"), "Free")
        XCTAssertEqual(AccountPlan.resolve(tier: nil, capabilities: ["chat"]), "Free")
        XCTAssertEqual(AccountPlan.resolve(tier: nil, capabilities: ["claude_free"]), "Free")
    }

    func testPaidAndManagedPlansDoNotBecomeFree() {
        for (tier, expected) in [("default_claude_max_20x", "Max 20x"), ("default_claude_max_5x", "Max 5x"),
                                 ("default_claude_pro", "Pro"), ("default_raven_team", "Team"),
                                 ("enterprise_tier_1", "Enterprise")] {
            XCTAssertEqual(AccountPlan.resolve(tier: tier, capabilities: ["chat"]), expected)
        }
        XCTAssertEqual(AccountPlan.resolve(tier: "default_claude_ai", capabilities: ["chat", "claude_pro"]), "Pro")
        XCTAssertEqual(AccountPlan.resolve(tier: nil, capabilities: ["chat", "raven"], ravenType: "enterprise"), "Enterprise")
        XCTAssertEqual(AccountPlan.resolve(tier: nil, capabilities: ["chat", "raven"], ravenType: "team"), "Team")
        XCTAssertEqual(AccountPlan.resolve(tier: "default_claude_ai", hasMax: true), "Max")
        XCTAssertEqual(AccountPlan.resolve(tier: "default_claude_ai", hasPro: true), "Pro")
        XCTAssertNil(AccountPlan.resolve(tier: "default_claude_max_20x", hasMax: false, hasPro: false))
        XCTAssertNil(AccountPlan.resolve(tier: "default_claude_pro", hasPro: false))
    }

    func testDowngradeUnknownAndUpgradeReplacePreviousServerPlan() throws {
        var account = Account(id: "0a1b2c3d-1111-4aaa-8bbb-000000000001", organizationID: organization)
        for (index, plan) in ["Max 20x", "Free", nil, "Pro", "Team"].enumerated() {
            let date = now.addingTimeInterval(Double(index))
            XCTAssertTrue(account.observePlan(plan, organizationID: organization, at: date, verified: true))
            account = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(account))
            XCTAssertEqual(account.plan, plan)
            XCTAssertEqual(account.planVerifiedAt, date)
        }
        XCTAssertFalse(account.observePlan("Free", organizationID: organization, at: now, verified: true))
        XCTAssertEqual(account.plan, "Team")
    }

    func testLocalCacheCannotRestoreAnExpiredPaidPlan() {
        var account = Account(id: "0a1b2c3d-1111-4aaa-8bbb-000000000001", organizationID: organization)
        account.observePlan("Max 20x", organizationID: organization, at: now.addingTimeInterval(100))
        account.observePlan("Free", organizationID: organization, at: now, verified: true)
        XCTAssertFalse(account.observePlan("Max 20x", organizationID: organization, at: now.addingTimeInterval(200)))
        XCTAssertEqual(account.plan, "Free")
        account.setOrganization("0a1b2c3d-5555-4aaa-8bbb-000000000005")
        XCTAssertNil(account.plan); XCTAssertNil(account.planVerifiedAt)
        XCTAssertFalse(account.observePlan("Pro", organizationID: organization, at: now, verified: true))
    }

    private func string(_ text: String) -> [UInt8] { [0x22, UInt8(text.utf8.count)] + Array(text.utf8) }
    private func blob(tier: String, capabilities: [String], complete: Bool = true) -> Data {
        var value = string("uuid") + string(organization) + string("capabilities") + [0x41, UInt8(capabilities.count)]
        for capability in capabilities { value += string(capability) }
        value += complete ? [0x24, 0, UInt8(capabilities.count)] : [0x3F]
        value += string("rate_limit_tier") + string(tier)
        return Data(value)
    }

    func testCachedDowngradeAndUnknownDoNotResurrectAnOlderPaidBlob() {
        for (tier, expected) in [("default_claude_ai", "Free" as String?), ("future_tier", nil)] {
            var latest = DesktopProfile.read(blob(tier: tier, capabilities: ["chat"]), observedAt: now)
            latest.merge(DesktopProfile.read(blob(tier: "default_claude_max_20x", capabilities: ["chat", "claude_max"]),
                                             observedAt: now.addingTimeInterval(-10)))
            XCTAssertEqual(latest.plans[organization], expected)
            XCTAssertEqual(latest.observedAt[organization], now)
        }
        let malformed = DesktopProfile.read(blob(tier: "default_claude_ai", capabilities: ["chat"], complete: false), observedAt: now)
        XCTAssertNil(malformed.plans[organization])
        var unsupported = blob(tier: "default_claude_ai", capabilities: ["chat"])
        unsupported.removeLast(2 + "default_claude_ai".utf8.count)
        unsupported.append(0x3F)
        XCTAssertNil(DesktopProfile.read(unsupported, observedAt: now).plans[organization])
    }

    func testLegacyAccountWithoutVerificationMetadataStillLoads() throws {
        let value = #"{"id":"0a1b2c3d-1111-4aaa-8bbb-000000000001","hasSnapshot":true,"plan":"Pro"}"#
        let account = try JSONDecoder().decode(Account.self, from: Data(value.utf8))
        XCTAssertEqual(account.plan, "Pro"); XCTAssertNil(account.planVerifiedAt)
    }
}
