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

    func testRejectedPreferredTokenDoesNotHideCodeReplacement() throws {
        let prefix = "acct:\(account)|\(client):\(org):https://api.anthropic.com:"
        let old = "synthetic-rejected", replacement = "synthetic-replacement"
        let entries: [String: JSONValue] = [
            prefix + "user:inference user:profile": .object(["token": .string(old),
                "expiresAt": .number(Date().addingTimeInterval(1800).timeIntervalSince1970)]),
            prefix + "user:inference user:profile user:sessions:claude_code": .object(["token": .string(replacement),
                "expiresAt": .number(Date().addingTimeInterval(3600).timeIntervalSince1970)])
        ]
        let auth = try savedAuth(entries: entries)
        let selected = try DesktopTokenReader.read(config: auth, expectedAccount: account,
            rejectedTokens: [digest(Data(old.utf8)): .forbidden]) { Data("fixture-password".utf8) }
        XCTAssertTrue(selected.value == replacement, "The usable replacement must not be hidden by the rejected preferred credential")
    }

    func testRejectedCandidatesPreserveIdentityAndAmbiguityGuards() throws {
        let prefix = "acct:\(account)|\(client):\(org):https://api.anthropic.com:"
        let old = "synthetic-rejected", replacement = "synthetic-replacement"
        let entry: (String) -> JSONValue = { .object(["token": .string($0),
            "expiresAt": .number(Date().addingTimeInterval(3600).timeIntervalSince1970)]) }
        let preferred = prefix + "user:inference user:profile"
        let code = prefix + "user:inference user:profile user:sessions:claude_code"
        let entries = [preferred: entry(old), code: entry(replacement)]
        let oldDigest = digest(Data(old.utf8)), replacementDigest = digest(Data(replacement.utf8))
        for failure in [UsageFailure.unauthorized, .forbidden, .missingScopes] {
            let auth = try savedAuth(entries: entries)
            let selected = try DesktopTokenReader.read(config: auth, expectedAccount: account,
                rejectedTokens: [oldDigest: failure]) { Data("fixture-password".utf8) }
            XCTAssertTrue(selected.value == replacement)
            XCTAssertThrowsError(try DesktopTokenReader.read(config: auth, expectedAccount: account,
                rejectedTokens: [oldDigest: failure, replacementDigest: .forbidden]) { Data("fixture-password".utf8) }) {
                XCTAssertEqual($0 as? UsageFailure, failure)
            }
        }
        let scenarios: [([String: JSONValue], UsageFailure, UsageFailure)] = [
            (entries, .identityMismatch, .identityMismatch),
            ([preferred: entry(old), prefix + "user:profile user:inference": entry(replacement)], .forbidden, .ambiguousCredentials),
            ([preferred: entry(old), "\(client):\(org):https://api.anthropic.com:user:inference user:profile": entry(replacement)], .forbidden, .forbidden),
            ([preferred: entry(old), "acct:\(account)|\(client):\(account):https://api.anthropic.com:user:inference user:profile": entry(replacement)], .forbidden, .ambiguousCredentials)
        ]
        for (cache, rejection, expected) in scenarios {
            let auth = try savedAuth(entries: cache)
            XCTAssertThrowsError(try DesktopTokenReader.read(config: auth, expectedAccount: account,
                rejectedTokens: [oldDigest: rejection]) { Data("fixture-password".utf8) }) {
                XCTAssertEqual($0 as? UsageFailure, expected)
            }
        }
    }

    func testPersisted403WithCodeReplacementRecoversWithoutRetryingRejectedToken() async throws {
        let home = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/token-recovery-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".local/share/claude/versions/1.0.0"),
                                                withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let env = MacEnvironment(home: home)
        let service = TokenRecoveryService(account: account, organization: org)
        var now = Date()
        let makeClient = { ActiveUsageClient(environment: env, transport: { _, request in try await service.respond(request) }, now: { now }) }
        let prefix = "acct:\(account)|\(client):\(org):https://api.anthropic.com:"
        let entry: (String) -> JSONValue = { .object(["token": .string($0),
            "expiresAt": .number(Date().addingTimeInterval(3600).timeIntervalSince1970)]) }
        let initial = try savedAuth(entries: [prefix + "user:inference user:profile": entry("synthetic-rejected")])
        let updated = try savedAuth(entries: [
            prefix + "user:inference user:profile": entry("synthetic-rejected"),
            prefix + "user:inference user:profile user:sessions:claude_code": entry("synthetic-replacement")])
        let first = makeClient()
        do {
            _ = try await first.fetch(accountID: account, readToken: {
                try DesktopTokenReader.read(config: initial, expectedAccount: self.account) { Data("fixture-password".utf8) }
            }, validate: { _ in })
            XCTFail("Expected the original HTTP rejection")
        } catch { XCTAssertEqual(error as? UsageFailure, .forbidden) }
        let restarted = makeClient()
        // The legacy selection still chooses the denied token even after the cache changes.
        do {
            _ = try await restarted.fetch(accountID: account, readToken: {
                try DesktopTokenReader.read(config: updated, expectedAccount: self.account) { Data("fixture-password".utf8) }
            }, validate: { _ in })
            XCTFail("Expected the legacy selection to replay the persisted rejection")
        } catch { XCTAssertEqual(error as? UsageFailure, .forbidden) }
        let readReplacement = {
            let rejected = try await restarted.rejectedTokenFailures()
            return try DesktopTokenReader.read(config: updated, expectedAccount: self.account,
                rejectedTokens: rejected) { Data("fixture-password".utf8) }
        }
        do {
            _ = try await restarted.fetch(accountID: account, readToken: readReplacement, validate: { _ in })
            XCTFail("Replacement must preserve the account cooldown")
        } catch { XCTAssertTrue(error is UsageCoolingDown) }
        now.addTimeInterval(61)
        let snapshot = try await restarted.fetch(accountID: account, readToken: readReplacement, validate: { _ in })
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 23)
        let paths = await service.paths
        XCTAssertEqual(paths, ["/api/oauth/profile", "/api/oauth/profile", "/api/oauth/usage"])
        let denied = try await restarted.rejectedTokenFailures()
        XCTAssertEqual(denied[digest(Data("synthetic-rejected".utf8))], .forbidden)
        do {
            _ = try await restarted.fetch(accountID: account, onlyIfTokenChanged: true, readToken: readReplacement, validate: { _ in })
            XCTFail("An unchanged replacement must not enqueue another request")
        } catch { XCTAssertTrue(error is UsageUnchanged) }
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

private actor TokenRecoveryService {
    let account: String
    let organization: String
    private(set) var paths: [String] = []
    init(account: String, organization: String) { self.account = account; self.organization = organization }
    func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        paths.append(url.path)
        let rejected = request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-rejected"
        let status = rejected ? 403 : 200
        let body: JSONValue = url.path.hasSuffix("/profile")
            ? .object(["account": .object(["uuid": .string(account)]), "organization": .object(["uuid": .string(organization)])])
            : .object(["five_hour": .object(["utilization": .number(23)])])
        return (try JSONEncoder().encode(body), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
