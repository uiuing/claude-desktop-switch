import XCTest
@testable import SwitchMac

final class DesktopTokenTests: XCTestCase {
    let account = "0a1b2c3d-1111-4aaa-8bbb-000000000001"
    let client = "0a1b2c3d-2222-4aaa-8bbb-000000000002"
    let org = "0a1b2c3d-3333-4aaa-8bbb-000000000003"

    func testUnboundKey() {
        let key = "\(client):\(org):https://api.anthropic.com:user:inference user:profile"
        XCTAssertEqual(DesktopTokenReader.usageOrganization(cacheKey: key, account: account), org)
    }

    func testAccountBoundKey() {
        let key = "acct:\(account)|\(client):\(org):https://api.anthropic.com:user:inference user:file_upload user:profile"
        XCTAssertEqual(DesktopTokenReader.usageOrganization(cacheKey: key, account: account), org)
        XCTAssertEqual(DesktopTokenReader.usageOrganization(cacheKey: key, account: account.uppercased()), org)
    }

    func testKeyBoundToAnotherAccount() {
        let other = "0a1b2c3d-4444-4aaa-8bbb-000000000004"
        let key = "acct:\(other)|\(client):\(org):https://api.anthropic.com:user:inference user:profile"
        XCTAssertNil(DesktopTokenReader.usageOrganization(cacheKey: key, account: account))
    }

    func testKeyWithoutUsageScopes() {
        let profileOnly = "acct:\(account)|\(client):\(org):https://api.anthropic.com:user:profile"
        let inferenceOnly = "\(client):\(org):https://api.anthropic.com:user:inference"
        XCTAssertNil(DesktopTokenReader.usageOrganization(cacheKey: profileOnly, account: account))
        XCTAssertNil(DesktopTokenReader.usageOrganization(cacheKey: inferenceOnly, account: account))
    }

    func testUnknownPrefix() {
        let key = "other:\(account)|\(client):\(org):https://api.anthropic.com:user:inference user:profile"
        XCTAssertNil(DesktopTokenReader.usageOrganization(cacheKey: key, account: account))
    }
}
