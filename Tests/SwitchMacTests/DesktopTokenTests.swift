import XCTest
import CommonCrypto
import SwitchCore
@testable import SwitchMac

final class DesktopTokenTests: XCTestCase {
    let account = "0a1b2c3d-1111-4aaa-8bbb-000000000001"
    let client = DesktopUsageProtocol.clientID
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

    func testSavedEncryptedAuthCanBeReadWithoutDesktopFilesOrKeychain() throws {
        let auth = try savedAuth()
        let token = try DesktopTokenReader.read(config: auth, expectedAccount: account) { Data("fixture-password".utf8) }
        XCTAssertEqual(token.accountID, account)
        XCTAssertEqual(token.organizationID, org)
        XCTAssertEqual(token.credentialDigest, try IdentitySchema.fingerprint(auth))
    }
    func testRotatedStorageKeyRetriesSilentlyAndStillValidatesAccount() throws {
        let access = KeychainKeyCache()
        _ = try access.read(allowPrompt: true) { _ in Data("fixture-old-key".utf8) }
        var loads = 0
        let token = try DesktopTokenReader.read(config: savedAuth(), expectedAccount: account, allowPrompt: false, access: access) { prompt in
            XCTAssertFalse(prompt)
            loads += 1
            return Data("fixture-password".utf8)
        }
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(token.accountID, account)
        XCTAssertEqual(token.organizationID, org)
        XCTAssertTrue(access.available)
    }

    func testDamagedSnapshotDoesNotDiscardAccessOrRepeatKeyReads() throws {
        let access = KeychainKeyCache()
        _ = try access.read(allowPrompt: true) { _ in Data("fixture-password".utf8) }
        let damaged: JSONValue = .object(["lastKnownAccountUuid": .string(account),
            "oauth:tokenCacheV2": .string((Data("v10".utf8) + Data([0])).base64EncodedString())])
        var loads = 0
        for _ in 0..<3 {
            XCTAssertThrowsError(try DesktopTokenReader.read(config: damaged, expectedAccount: account, allowPrompt: true, access: access) { _ in
                loads += 1
                return Data("fixture-password".utf8)
            })
            XCTAssertTrue(access.available)
        }
        XCTAssertEqual(loads, 1)
        let token = try DesktopTokenReader.read(config: savedAuth(), expectedAccount: account, allowPrompt: false, access: access) { _ in
            XCTFail("A damaged snapshot must not revoke access for a valid login")
            throw UsageFailure.keychain
        }
        XCTAssertEqual(token.accountID, account)
    }

    func testFreshAuthorizationDoesNotImmediatelyReadTheKeyAgain() throws {
        let access = KeychainKeyCache()
        let damaged: JSONValue = .object(["lastKnownAccountUuid": .string(account),
            "oauth:tokenCacheV2": .string((Data("v10".utf8) + Data([0])).base64EncodedString())])
        var loads = 0
        XCTAssertThrowsError(try DesktopTokenReader.read(config: damaged, expectedAccount: account, allowPrompt: true, access: access) { allowed in
            XCTAssertTrue(allowed)
            loads += 1
            return Data("fixture-password".utf8)
        })
        XCTAssertEqual(loads, 1)
        XCTAssertTrue(access.available)
    }

    func testDeniedKeyRecheckKeepsOtherLoginsUsableAndManualRefreshCanAuthorize() throws {
        let access = KeychainKeyCache()
        _ = try access.read(allowPrompt: true) { _ in Data("fixture-old-key".utf8) }
        let auth = try savedAuth()
        XCTAssertThrowsError(try DesktopTokenReader.read(config: auth, expectedAccount: account, allowPrompt: false, access: access) { allowed in
            XCTAssertFalse(allowed)
            throw UsageFailure.keychain
        }) { XCTAssertEqual($0 as? UsageFailure, .keychain) }
        XCTAssertTrue(access.available)
        let old = try DesktopTokenReader.read(config: savedAuth(password: Data("fixture-old-key".utf8)), expectedAccount: account,
                                              allowPrompt: false, access: access) { _ in
            XCTFail("A denied recheck must leave the existing authorized key usable")
            throw UsageFailure.keychain
        }
        XCTAssertEqual(old.accountID, account)
        var approvals = 0
        let renewed = try DesktopTokenReader.read(config: auth, expectedAccount: account, allowPrompt: true, access: access) { allowed in
            XCTAssertTrue(allowed)
            approvals += 1
            return Data("fixture-password".utf8)
        }
        XCTAssertEqual(approvals, 1)
        XCTAssertEqual(renewed.accountID, account)
    }

    func testSavedAuthRejectsWrongAccountBeforeReadingKey() throws {
        let auth = try savedAuth()
        XCTAssertThrowsError(try DesktopTokenReader.read(config: auth, expectedAccount: client) {
            XCTFail("A mismatched login must not access the encryption key")
            return Data()
        })
    }

    func testSavedAuthRejectsExpiredTokenAndAmbiguousOrganizations() throws {
        for auth in [try savedAuth(expired: true), try savedAuth(ambiguous: true)] {
            XCTAssertThrowsError(try DesktopTokenReader.read(config: auth, expectedAccount: account) { Data("fixture-password".utf8) })
        }
    }

    func testSavedAuthRejectsUnknownOAuthFieldsBeforeReadingKey() throws {
        var auth = try XCTUnwrap(savedAuth().object)
        auth["oauth:unknown"] = .string("synthetic")
        XCTAssertThrowsError(try DesktopTokenReader.read(config: .object(auth), expectedAccount: account) {
            XCTFail("Unknown formats must not access the encryption key")
            return Data()
        })
    }

    func testUnknownClientAudienceAndExtraScopeFailClosed() {
        for key in [
            "0a1b2c3d-2222-4aaa-8bbb-000000000002:\(org):https://api.anthropic.com:user:inference user:profile",
            "\(client):\(org):https://api.anthropic.com.evil:user:inference user:profile",
            "\(client):\(org):https://api.anthropic.com:user:inference user:profile user:unknown"
        ] { XCTAssertNil(DesktopTokenReader.usageOrganization(cacheKey: key, account: account)) }
    }

    func testEquivalentCredentialCandidatesMustAgreeInsteadOfPickingLatestExpiry() throws {
        let prefix = "acct:\(account)|\(client):\(org):https://api.anthropic.com:"
        let entries: [String: JSONValue] = [
            prefix + "user:inference user:profile": .object(["token": .string("synthetic-one"), "expiresAt": .number(Date().addingTimeInterval(300).timeIntervalSince1970)]),
            prefix + "user:profile user:inference": .object(["token": .string("synthetic-two"), "expiresAt": .number(Date().addingTimeInterval(3600).timeIntervalSince1970)])
        ]
        let auth = try savedAuth(entries: entries)
        XCTAssertThrowsError(try DesktopTokenReader.read(config: auth, expectedAccount: account) { Data("fixture-password".utf8) }) {
            XCTAssertEqual($0 as? UsageFailure, .ambiguousCredentials)
        }
    }

    func testActualExpiryDistinguishesExpiredExpiringAndMalformed() throws {
        for seconds in [-60.0, 30, 3600] {
            let key = "acct:\(account)|\(client):\(org):https://api.anthropic.com:user:inference user:profile"
            let expiry: JSONValue = seconds == 3600 ? .string("invalid") : .number(Date().addingTimeInterval(seconds).timeIntervalSince1970)
            let auth = try savedAuth(entries: [key: .object(["token": .string("synthetic"), "expiresAt": expiry])])
            XCTAssertThrowsError(try DesktopTokenReader.read(config: auth, expectedAccount: account) { Data("fixture-password".utf8) }) {
                if seconds == 3600 { XCTAssertEqual($0 as? UsageFailure, .invalidCredentials) }
                else { XCTAssertEqual(($0 as? UsageNotReady)?.reason, seconds < 0 ? .expired : .expiring) }
            }
        }
    }

    private func savedAuth(expired: Bool = false, ambiguous: Bool = false, entries: [String: JSONValue]? = nil,
                           password: Data = Data("fixture-password".utf8)) throws -> JSONValue {
        let entry: JSONValue = .object(["token": .string("synthetic-access"),
                                       "expiresAt": .number(Date().addingTimeInterval(expired ? -60 : 3600).timeIntervalSince1970)])
        let suffix = ":https://api.anthropic.com:user:inference user:profile"
        var cache = ["acct:\(account)|\(client):\(org)" + suffix: entry]
        if ambiguous { cache["acct:\(account)|\(client):\(client)" + suffix] = entry }
        let plain = try JSONEncoder().encode(JSONValue.object(entries ?? cache))
        let salt = Data("saltysalt".utf8), iv = Data(repeating: 0x20, count: 16)
        var key = Data(count: 16)
        let derive = key.withUnsafeMutableBytes { output in
            password.withUnsafeBytes { secret in salt.withUnsafeBytes { salt in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), secret.bindMemory(to: Int8.self).baseAddress,
                    password.count, salt.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, output.bindMemory(to: UInt8.self).baseAddress, 16)
            } }
        }
        guard derive == kCCSuccess else { throw SwitchError.changed }
        var cipher = Data(count: plain.count + 16), written = 0
        let capacity = cipher.count
        let status = cipher.withUnsafeMutableBytes { output in plain.withUnsafeBytes { input in
            key.withUnsafeBytes { key in iv.withUnsafeBytes { iv in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        key.baseAddress, key.count, iv.baseAddress, input.baseAddress, input.count,
                        output.baseAddress, capacity, &written)
            } }
        } }
        guard status == kCCSuccess else { throw SwitchError.changed }
        cipher.count = written
        return .object(["lastKnownAccountUuid": .string(account),
                        "oauth:tokenCacheV2": .string((Data("v10".utf8) + cipher).base64EncodedString())])
    }
}
