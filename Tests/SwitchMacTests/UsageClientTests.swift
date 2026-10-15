import XCTest
import SwitchCore
import SwitchStorage
@testable import SwitchMac

final class UsageClientTests: XCTestCase {
    private let accountA = "0a1b2c3d-1111-4aaa-8bbb-000000000001"
    private let accountB = "0a1b2c3d-2222-4aaa-8bbb-000000000002"
    private let organization = "0a1b2c3d-3333-4aaa-8bbb-000000000003"

    private func environment() throws -> MacEnvironment {
        let home = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/usage-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".local/share/claude/versions/1.0.0"),
                                                withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return MacEnvironment(home: home)
    }
    private func token(_ account: String, generation: String = "1") -> DesktopAccessToken {
        let value = "synthetic-access-" + account + "-" + generation
        return DesktopAccessToken(value: value, accountID: account, credentialDigest: digest(Data(value.utf8)),
                                  expiresAt: Date().addingTimeInterval(3600), organizationID: organization)
    }
    private func service() -> UsageFixtureService {
        UsageFixtureService(accounts: [token(accountA).value: accountA, token(accountB).value: accountB,
                                       token(accountA, generation: "2").value: accountA], organization: organization)
    }
    private func client(_ env: MacEnvironment, service: UsageFixtureService, clock: FixtureClock = FixtureClock()) -> ActiveUsageClient {
        ActiveUsageClient(environment: env, transport: { _, request in try await service.respond(request) }, now: { clock.date })
    }
    private func fetch(_ client: ActiveUsageClient, _ account: String, generation: String = "1", profileRefreshID: UUID? = nil) async throws -> UsageSnapshot {
        try await client.fetch(accountID: account, profileRefreshID: profileRefreshID,
                               readToken: { self.token(account, generation: generation) }, validate: { _ in })
    }

    func testSelectedLoginWorksWithoutDesktopBeingSignedIn() async throws {
        let env = try environment(), service = service(), client = client(env, service: service)
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.desktop.path))
        let snapshot = try await fetch(client, accountB)
        XCTAssertEqual(snapshot.accountID, accountB)
        XCTAssertEqual(snapshot.organizationID, organization)
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 23)
        XCTAssertEqual(snapshot.origin, .live)
        let identity = await client.identity()
        XCTAssertEqual(identity?.id, accountB)
        let requests = await service.paths
        XCTAssertEqual(requests, ["/api/oauth/profile", "/api/oauth/usage"])
        let queries = await service.queries
        XCTAssertEqual(queries, [nil, "skip_spend=1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.desktop.path))
    }

    func testProfileEmailIsReturnedWithQuotaForEachSupportedField() async throws {
        for field in ["email", "email_address", "emailAddress"] {
            let env = try environment(), service = service(), client = client(env, service: service)
            await service.setProfile(.object([
                "account": .object(["uuid": .string(accountA), field: .string("mi•••el@gmail.com")]),
                "organization": .object(["uuid": .string(organization)])
            ]))
            let snapshot = try await fetch(client, accountA)
            let identity = await client.identity()
            XCTAssertEqual(identity?.email, "mi•••el@gmail.com", field)
            XCTAssertEqual(identity?.id, snapshot.accountID)
            let paths = await service.paths
            XCTAssertEqual(paths, ["/api/oauth/profile", "/api/oauth/usage"])
        }
    }

    func testCanonicalProfileEmailWinsAndEmptyFieldsFallBack() async throws {
        for value in ["mi•••el@gmail.com", "", " \n", "invalid", "mi•••el@gmail.com\nInjected"] {
            let env = try environment(), service = service(), client = client(env, service: service)
            await service.setProfile(.object([
                "account": .object(["uuid": .string(accountA), "email": .string(value),
                                    "email_address": .string("al•••ce@outlook.com")]),
                "organization": .object(["uuid": .string(organization)])
            ]))
            _ = try await fetch(client, accountA)
            let identity = await client.identity()
            XCTAssertEqual(identity?.email, value == "mi•••el@gmail.com" ? value : "al•••ce@outlook.com")
        }
    }

    func testMissingAccountEmailDoesNotBorrowAnUnrelatedAddress() async throws {
        let env = try environment(), service = service(), client = client(env, service: service)
        await service.setProfile(.object([
            "email": .string("al•••ce@outlook.com"),
            "account": .object(["uuid": .string(accountA)]),
            "organization": .object(["uuid": .string(organization), "email": .string("te•••am@gmail.com")])
        ]))
        let snapshot = try await fetch(client, accountA)
        let identity = await client.identity()
        XCTAssertNil(identity?.email)
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 23)
    }

    func testAutomaticRefreshReusesVerifiedTokenWithoutRepublishingMetadata() async throws {
        let env = try environment(), service = service(), clock = FixtureClock()
        let client = client(env, service: service, clock: clock)
        await service.setProfile(.object([
            "account": .object(["uuid": .string(accountA), "email": .string("mi•••el@gmail.com")]),
            "organization": .object(["uuid": .string(organization)])
        ]))
        _ = try await fetch(client, accountA)
        for interval in [61.0, 601, 901] {
            clock.advance(interval)
            _ = try await fetch(client, accountA)
        }
        let identity = await client.identity()
        let plan = await client.takeVerifiedPlan()
        XCTAssertNil(identity); XCTAssertNil(plan)
        let paths = await service.paths
        XCTAssertEqual(paths, ["/api/oauth/profile", "/api/oauth/usage", "/api/oauth/usage", "/api/oauth/usage", "/api/oauth/usage"])
    }

    private func profile(plan: String?) -> JSONValue {
        var org: [String: JSONValue] = ["uuid": .string(organization)]
        if let plan { org["rate_limit_tier"] = .string(plan) }
        return .object(["account": .object(["uuid": .string(accountA)]), "organization": .object(org)])
    }

    func testManualRefreshReadsPlanChangesWithoutTokenRenewal() async throws {
        let env = try environment(), service = service(), clock = FixtureClock()
        let client = client(env, service: service, clock: clock)
        for (tier, expected) in [("default_claude_max_20x", "Max 20x" as String?), ("default_claude_ai", "Free"),
                                 ("future_tier", nil), ("default_claude_pro", "Pro")] {
            await service.setProfile(profile(plan: tier))
            _ = try await fetch(client, accountA, profileRefreshID: UUID())
            let verified = await client.takeVerifiedPlan()
            XCTAssertNotNil(verified)
            XCTAssertEqual(verified?.plan, expected)
            XCTAssertEqual(verified?.observedAt, clock.date)
            clock.advance(61)
        }
    }

    func testVerifiedDowngradeSurvivesUsageDenialOrUnavailableQuota() async throws {
        for status in [403, 429, 503, 200] {
            let env = try environment(), service = service(), client = client(env, service: service)
            await service.setProfile(profile(plan: "default_claude_ai"))
            await service.setUsageStatus(status)
            if status == 200 { await service.setUsageBody(.object([:])) }
            do { _ = try await fetch(client, accountA); XCTFail("Expected unavailable quota") } catch {}
            let verified = await client.takeVerifiedPlan(), identity = await client.identity()
            XCTAssertEqual(verified?.plan, "Free")
            XCTAssertEqual(identity?.id, accountA)
            let consumed = await client.takeVerifiedPlan()
            XCTAssertNil(consumed)
        }
    }

    func testMalformedOrMissingPlanMetadataPublishesUnknownInsteadOfFree() async throws {
        for field in [JSONValue.null, .string("false")] {
            let env = try environment(), service = service(), client = client(env, service: service)
            await service.setProfile(.object([
                "account": .object(["uuid": .string(accountA), "has_claude_pro": field]),
                "organization": .object(["uuid": .string(organization)])
            ]))
            _ = try await fetch(client, accountA)
            let verified = await client.takeVerifiedPlan()
            XCTAssertNotNil(verified); XCTAssertNil(verified?.plan)
        }
    }

    func testProfileFailureNeverReplacesAPreviouslyConfirmedPaidPlan() async throws {
        for status in [401, 403, 429, 503] {
            let env = try environment(), service = service(), clock = FixtureClock()
            let client = client(env, service: service, clock: clock)
            await service.setProfile(profile(plan: "default_claude_max_20x"))
            _ = try await fetch(client, accountA)
            let previous = await client.takeVerifiedPlan()
            XCTAssertEqual(previous?.plan, "Max 20x")
            clock.advance(61)
            await service.reject(accountA, status: status)
            do { _ = try await fetch(client, accountA, profileRefreshID: UUID()); XCTFail("Expected profile query failure") } catch {}
            let verified = await client.takeVerifiedPlan(), identity = await client.identity()
            XCTAssertNil(verified); XCTAssertNil(identity)
        }
    }

    func testChangedProfileIdentityCannotPublishThePreviousAccountsPlan() async throws {
        let env = try environment(), service = service(), clock = FixtureClock()
        let client = client(env, service: service, clock: clock)
        await service.setProfile(profile(plan: "default_claude_pro"))
        _ = try await fetch(client, accountA)
        clock.advance(61)
        await service.setProfile(.object([
            "account": .object(["uuid": .string(accountB)]),
            "organization": .object(["uuid": .string(organization), "rate_limit_tier": .string("default_claude_ai")])
        ]))
        do { _ = try await fetch(client, accountA, profileRefreshID: UUID()); XCTFail("Expected mismatched profile") }
        catch let failure as UsageFailure { XCTAssertEqual(failure, .identityMismatch) }
        let verified = await client.takeVerifiedPlan(), identity = await client.identity()
        XCTAssertNil(verified); XCTAssertNil(identity)
    }

    func testMismatchedProfileNeverPublishesEmail() async throws {
        let env = try environment(), service = service(), client = client(env, service: service)
        await service.setProfile(.object([
            "account": .object(["uuid": .string(accountB), "email": .string("al•••ce@outlook.com")]),
            "organization": .object(["uuid": .string(organization)])
        ]))
        do { _ = try await fetch(client, accountA); XCTFail("Expected identity mismatch") }
        catch let failure as UsageFailure { XCTAssertEqual(failure, .identityMismatch) }
        let identity = await client.identity()
        XCTAssertNil(identity)
        let paths = await service.paths
        XCTAssertEqual(paths, ["/api/oauth/profile"])
    }

    func testAlternatingAccountsKeepsBothCooldownsAcrossRelaunch() async throws {
        let env = try environment(), service = service(), client = client(env, service: service)
        _ = try await fetch(client, accountA)
        _ = try await fetch(client, accountB)
        let relaunched = self.client(env, service: service)
        for candidate in [client, relaunched] {
            for account in [accountA, accountB] {
                do { _ = try await fetch(candidate, account); XCTFail("Expected a per-login cooldown") }
                catch is UsageCoolingDown {} catch { XCTFail("Unexpected error type") }
            }
        }
        let requests = await service.paths
        XCTAssertEqual(requests.count, 4)
        let data = try SafeFiles.read(env.root.appendingPathComponent("usage-cooldown.json"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("synthetic-access-"))
    }

    func testRejectedLoginStaysBlockedAfterOtherAccountAndRelaunch() async throws {
        let env = try environment(), service = service(), client = client(env, service: service)
        await service.reject(accountA, status: 401)
        do { _ = try await fetch(client, accountA); XCTFail("Expected a rejection") } catch is UsageFailure {}
        _ = try await fetch(client, accountB)
        let relaunched = self.client(env, service: service)
        do { _ = try await fetch(relaunched, accountA); XCTFail("Expected the rejected login to stay blocked") }
        catch is UsageFailure {}
        let count = await service.paths.count
        XCTAssertEqual(count, 3)
        await service.reject(accountA, status: nil)
        do { _ = try await fetch(relaunched, accountA, generation: "2"); XCTFail("A new token must respect the account cooldown") }
        catch is UsageCoolingDown {}
    }

    func testRetryAfterRemainsScopedToAccountAcrossTokenChanges() async throws {
        let env = try environment(), service = service(), client = client(env, service: service)
        await service.reject(accountA, status: 429)
        do { _ = try await fetch(client, accountA); XCTFail("Expected rate limiting") }
        catch let error as UsageCoolingDown { XCTAssertGreaterThan(error.until.timeIntervalSinceNow, 580) }
        _ = try await fetch(client, accountB)
        for generation in ["1", "2"] {
            do { _ = try await fetch(self.client(env, service: service), accountA, generation: generation); XCTFail("Expected cooldown") }
            catch let error as UsageCoolingDown { XCTAssertGreaterThan(error.until.timeIntervalSinceNow, 580) }
        }
    }

    func testAccountAndOrganizationMismatchStopBeforeUsage() async throws {
        for mismatch in [accountB, organization] {
            let env = try environment(), service = service(), client = client(env, service: service)
            await service.mismatch(mismatch)
            do { _ = try await fetch(client, accountA); XCTFail("Expected identity validation to stop") } catch is UsageFailure {}
            let requests = await service.paths
            XCTAssertEqual(requests, ["/api/oauth/profile"])
            let identity = await client.identity()
            XCTAssertNil(identity)
        }
    }

    func testCredentialChangeDuringRequestDiscardsReading() async throws {
        let env = try environment(), service = service(), client = client(env, service: service)
        do {
            _ = try await client.fetch(accountID: accountA, readToken: { self.token(self.accountA) }, validate: { _ in
                if await service.paths.last == "/api/oauth/usage" { throw SwitchError.changed }
            })
            XCTFail("Expected changed credentials to discard the response")
        } catch SwitchError.changed {}
        let paths = await service.paths
        XCTAssertEqual(paths, ["/api/oauth/profile", "/api/oauth/usage"])
        let verified = await client.takeVerifiedPlan(), identity = await client.identity()
        XCTAssertNil(verified); XCTAssertNil(identity)
    }

    func testCredentialChangeBeforeUsageStopsRequest() async throws {
        let env = try environment(), service = service(), client = client(env, service: service)
        var validations = 0
        do {
            _ = try await client.fetch(accountID: accountA, readToken: { self.token(self.accountA) }, validate: { _ in
                validations += 1
                if validations == 2 { throw SwitchError.changed }
            })
            XCTFail("Expected changed credentials to stop")
        } catch SwitchError.changed {}
        let requests = await service.paths
        XCTAssertEqual(requests, ["/api/oauth/profile"])
    }

    func testWrongTokenOwnerNeverReachesNetwork() async throws {
        let env = try environment(), service = service(), client = client(env, service: service)
        do {
            _ = try await client.fetch(accountID: accountA, readToken: { self.token(self.accountB) }, validate: { _ in })
            XCTFail("Expected mismatched credential owner to stop")
        } catch SwitchError.changed {}
        let requests = await service.paths
        XCTAssertTrue(requests.isEmpty)
    }

    func testLegacyCooldownAndDenialArePreserved() async throws {
        let env = try environment(), service = service()
        try SafeFiles.privateDirectory(env.root)
        let state: JSONValue = .object([
            "cooldownDigest": .string(token(accountA).credentialDigest),
            "cooldownUntil": .number(Date().addingTimeInterval(600).timeIntervalSince1970),
            "deniedDigest": .string(token(accountB).credentialDigest)
        ])
        try SafeFiles.atomicWrite(JSONEncoder().encode(state), to: env.root.appendingPathComponent("usage-cooldown.json"))
        let client = client(env, service: service)
        do { _ = try await fetch(client, accountA); XCTFail("Expected legacy cooldown") } catch is UsageCoolingDown {}
        do { _ = try await fetch(client, accountB); XCTFail("Expected legacy denial") } catch is UsageFailure {}
        let requests = await service.paths
        XCTAssertTrue(requests.isEmpty)
    }

    func testCurrentLoginDoesNotFallBackToSavedLogin() async throws {
        let env = try environment(), service = service(), client = client(env, service: service)
        try SafeFiles.privateDirectory(env.desktop)
        try SafeFiles.atomicWrite(JSONEncoder().encode(JSONValue.object(["lastKnownAccountUuid": .string(accountA)])),
                                  to: env.desktop.appendingPathComponent("config.json"))
        do { _ = try await client.fetchCurrent(accountID: accountA); XCTFail("Expected a signed-out login to stop") }
        catch is UsageNotReady {}
        let requests = await service.paths
        XCTAssertTrue(requests.isEmpty)
    }

    func testRenewedTokenRecoversAfterCooldownAndOnlyOnce() async throws {
        let env = try environment(), service = service(), clock = FixtureClock()
        let client = client(env, service: service, clock: clock)
        await service.reject(accountA, status: 401)
        do { _ = try await fetch(client, accountA); XCTFail("Expected unauthorized") }
        catch let error as UsageFailure { XCTAssertEqual(error, .unauthorized) }
        clock.advance(300)
        let original = token(accountA)
        let sameToken = DesktopAccessToken(value: original.value, accountID: original.accountID,
                                          credentialDigest: digest(Data("changed encrypted cache".utf8)),
                                          expiresAt: original.expiresAt, organizationID: original.organizationID)
        do { _ = try await client.fetch(accountID: accountA, readToken: { sameToken }, validate: { _ in }); XCTFail("Storage changes cannot clear denial") }
        catch let error as UsageFailure { XCTAssertEqual(error, .unauthorized) }
        await service.reject(accountA, status: nil)
        let snapshot = try await client.fetch(accountID: accountA, onlyIfTokenChanged: true,
                                              readToken: { self.token(self.accountA, generation: "2") }, validate: { _ in })
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 23)
        do { _ = try await client.fetch(accountID: accountA, onlyIfTokenChanged: true,
                                        readToken: { self.token(self.accountA, generation: "2") }, validate: { _ in }); XCTFail("Duplicate generation") }
        catch is UsageUnchanged {}
        let count = await service.paths.count
        XCTAssertEqual(count, 3)
    }

    func testProfileIsRecheckedOnlyAcrossTokenChanges() async throws {
        let env = try environment(), service = service(), clock = FixtureClock()
        let client = client(env, service: service, clock: clock)
        _ = try await fetch(client, accountA)
        clock.advance(61)
        _ = try await fetch(client, accountA)
        clock.advance(61)
        _ = try await fetch(client, accountA, generation: "2")
        clock.advance(601)
        _ = try await fetch(client, accountA, generation: "2")
        let paths = await service.paths
        XCTAssertEqual(paths.filter { $0.hasSuffix("profile") }.count, 2)
        XCTAssertEqual(paths.filter { $0.hasSuffix("usage") }.count, 4)
    }

    func testSwitchRefreshReadsProfileOnceEvenWhenUsageNeedsRetry() async throws {
        let env = try environment(), service = service(), clock = FixtureClock()
        let client = client(env, service: service, clock: clock), switchID = UUID()
        _ = try await fetch(client, accountA)
        clock.advance(61)
        await service.setProfile(profile(plan: "default_claude_ai"))
        await service.setUsageStatus(503)
        do { _ = try await fetch(client, accountA, profileRefreshID: switchID); XCTFail("Expected temporary failure") }
        catch let error as UsageFailure { XCTAssertEqual(error, .server) }
        let plan = await client.takeVerifiedPlan()
        XCTAssertEqual(plan?.plan, "Free")
        clock.advance(601)
        await service.setUsageStatus(200)
        _ = try await fetch(client, accountA, profileRefreshID: switchID)
        let repeatedPlan = await client.takeVerifiedPlan(), identity = await client.identity()
        XCTAssertNil(repeatedPlan); XCTAssertNil(identity)
        let paths = await service.paths
        XCTAssertEqual(paths, ["/api/oauth/profile", "/api/oauth/usage", "/api/oauth/profile", "/api/oauth/usage", "/api/oauth/usage"])
    }

    func testManualRefreshReadsProfileForEachSelectedAccount() async throws {
        let env = try environment(), service = service(), clock = FixtureClock()
        let client = client(env, service: service, clock: clock)
        for _ in 0..<2 {
            for account in [accountA, accountB] {
                _ = try await fetch(client, account, profileRefreshID: UUID())
                let identity = await client.identity()
                XCTAssertEqual(identity?.id, account)
            }
            clock.advance(61)
        }
        let paths = await service.paths
        XCTAssertEqual(paths, Array(repeating: ["/api/oauth/profile", "/api/oauth/usage"], count: 4).flatMap { $0 })
    }

    func testCachedValidationCannotBypassOrganizationMismatchOrTokenExpiry() async throws {
        let env = try environment(), service = service(), clock = FixtureClock()
        let client = client(env, service: service, clock: clock), original = token(accountA)
        _ = try await fetch(client, accountA)
        clock.advance(61)
        let otherOrg = DesktopAccessToken(value: original.value, accountID: original.accountID, credentialDigest: original.credentialDigest,
                                         expiresAt: original.expiresAt, organizationID: accountB)
        do { _ = try await client.fetch(accountID: accountA, readToken: { otherOrg }, validate: { _ in }); XCTFail("Expected mismatch") }
        catch let error as UsageFailure { XCTAssertEqual(error, .identityMismatch) }
        let paths = await service.paths
        XCTAssertEqual(paths, ["/api/oauth/profile", "/api/oauth/usage", "/api/oauth/profile"])
        clock.advance(3601)
        do { _ = try await client.fetch(accountID: accountA, readToken: { original }, validate: { _ in }); XCTFail("Expected expired token") }
        catch is UsageNotReady {}
        let finalPaths = await service.paths
        XCTAssertEqual(finalPaths, paths)
    }

    func testUsageRejectionBlocksPreviouslyVerifiedTokenAcrossRelaunch() async throws {
        let env = try environment(), service = service(), clock = FixtureClock()
        let client = client(env, service: service, clock: clock)
        _ = try await fetch(client, accountA)
        clock.advance(61)
        await service.setUsageStatus(401)
        do { _ = try await fetch(client, accountA); XCTFail("Expected rejection") }
        catch let error as UsageFailure { XCTAssertEqual(error, .unauthorized) }
        clock.advance(601)
        for candidate in [client, self.client(env, service: service, clock: clock)] {
            do { _ = try await fetch(candidate, accountA); XCTFail("Expected persisted rejection") }
            catch let error as UsageFailure { XCTAssertEqual(error, .unauthorized) }
        }
        let paths = await service.paths
        XCTAssertEqual(paths, ["/api/oauth/profile", "/api/oauth/usage", "/api/oauth/usage"])
        await service.setUsageStatus(200)
        _ = try await fetch(client, accountA, generation: "2")
        let finalPaths = await service.paths
        XCTAssertEqual(finalPaths.suffix(2), ["/api/oauth/profile", "/api/oauth/usage"])
    }

    func testRetryAfterLongerThanAnHourAndHTTPDateSurviveRelaunch() async throws {
        for httpDate in [false, true] {
            let env = try environment(), service = service(), clock = FixtureClock()
            let until = clock.date.addingTimeInterval(7200)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            await service.setRetryAfter(httpDate ? formatter.string(from: until) : "7200")
            await service.reject(accountA, status: 429)
            for reader in [client(env, service: service, clock: clock), client(env, service: service, clock: clock)] {
                do { _ = try await fetch(reader, accountA); XCTFail("Expected cooldown") }
                catch let error as UsageCoolingDown { XCTAssertEqual(error.until.timeIntervalSince(clock.date), 7200, accuracy: 1) }
            }
            let paths = await service.paths
            XCTAssertEqual(paths.count, 1)
        }
    }

    func testForbiddenAndScopeFailuresAreNotTreatedAsRateLimits() async throws {
        for scope in [false, true] {
            let env = try environment(), service = service()
            await service.reject(accountA, status: 403)
            if scope { await service.setBody(.object(["error": .object(["type": .string("missing_scope")])])) }
            for reader in [client(env, service: service), client(env, service: service)] {
                do { _ = try await fetch(reader, accountA); XCTFail("Expected authorization failure") }
                catch let error as UsageFailure { XCTAssertEqual(error, scope ? .missingScopes : .forbidden) }
            }
            let paths = await service.paths
            XCTAssertEqual(paths.count, 1)
        }
    }

    func testServerBackoffDoesNotRejectCredential() async throws {
        let env = try environment(), service = service(), clock = FixtureClock()
        let client = client(env, service: service, clock: clock)
        await service.reject(accountA, status: 503)
        await service.setRetryAfter("120")
        do { _ = try await fetch(client, accountA); XCTFail("Expected temporary failure") }
        catch let error as UsageFailure { XCTAssertEqual(error, .server) }
        do { _ = try await fetch(client, accountA); XCTFail("Expected retry delay") }
        catch let error as UsageCoolingDown { XCTAssertEqual(error.until.timeIntervalSince(clock.date), 120, accuracy: 1) }
        clock.advance(121)
        await service.reject(accountA, status: nil)
        _ = try await fetch(client, accountA)
    }

    func testCancellationAndOfflineAreDistinct() async throws {
        for code in [URLError.cancelled, .notConnectedToInternet] {
            let env = try environment()
            let client = ActiveUsageClient(environment: env, transport: { _, _ in throw URLError(code) })
            do { _ = try await fetch(client, accountA); XCTFail("Expected transport failure") }
            catch is CancellationError { XCTAssertEqual(code, .cancelled) }
            catch let error as UsageFailure { XCTAssertEqual(code, .notConnectedToInternet); XCTAssertEqual(error, .offline) }
        }
    }

    func testProtocolAllowsOnlyBoundedReadOnlyEndpoints() throws {
        for path in ["/api/oauth/profile", "/api/oauth/usage"] {
            let request = try DesktopUsageProtocol.request(path: path, token: "synthetic", codeVersion: "1.0.0")
            XCTAssertEqual(request.url?.host, "api.anthropic.com")
            XCTAssertEqual(request.url?.path, path)
            XCTAssertEqual(request.url?.query, path == "/api/oauth/usage" ? "skip_spend=1" : nil)
            XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "claude-code/1.0.0")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        }
        XCTAssertThrowsError(try DesktopUsageProtocol.request(path: "/v1/messages", token: "synthetic", codeVersion: "1.0.0"))
        XCTAssertThrowsError(try DesktopUsageProtocol.request(path: "/oauth/token", token: "synthetic", codeVersion: "1.0.0"))
        XCTAssertThrowsError(try DesktopUsageProtocol.request(path: "/api/oauth/usage?skip_spend=0", token: "synthetic", codeVersion: "1.0.0"))
    }

    func testCancellationDuringCredentialReadStopsBeforeNetwork() async throws {
        let env = try environment(), service = service(), client = client(env, service: service)
        let ready = expectation(description: "Credential read started")
        let gate = TokenGate()
        let task = Task {
            try await client.fetch(accountID: accountA, readToken: {
                ready.fulfill()
                await gate.wait()
                return self.token(self.accountA)
            }, validate: { _ in })
        }
        await fulfillment(of: [ready], timeout: 2)
        await client.cancelCurrentRead()
        await gate.release()
        do { _ = try await task.value; XCTFail("Expected cancellation before requesting") }
        catch is CancellationError {}
        let count = await service.paths.count
        XCTAssertEqual(count, 0)
    }

    func testUnknownSchedulerVersionDoesNotResetRequestBudget() async throws {
        for json in [#"{"version":99}"#, #"{"version":2,"scopeCooldowns":"invalid"}"#,
                     #"{"version":2,"deniedTokens":{"synthetic-digest":"unknown"}}"#] {
            let env = try environment(), service = service(), client = client(env, service: service)
            try SafeFiles.privateDirectory(env.root)
            try SafeFiles.atomicWrite(Data(json.utf8), to: env.root.appendingPathComponent("usage-cooldown.json"))
            do { _ = try await fetch(client, accountA); XCTFail("Unknown state must stop the request") }
            catch is SwitchError {}
            let count = await service.paths.count
            XCTAssertEqual(count, 0)
        }
    }

    func testCredentialChangeTriggerCanRetryTemporaryFailuresWithSameToken() async throws {
        for status in [429, 503] {
            let env = try environment(), service = service(), clock = FixtureClock()
            let client = client(env, service: service, clock: clock)
            await service.reject(accountA, status: status)
            do {
                _ = try await client.fetch(accountID: accountA, onlyIfTokenChanged: true,
                                           readToken: { self.token(self.accountA) }, validate: { _ in })
                XCTFail("Expected a retryable failure")
            } catch is UsageCoolingDown { XCTAssertEqual(status, 429) }
            catch let failure as UsageFailure { XCTAssertEqual(failure, .server) }
            clock.advance(601)
            await service.reject(accountA, status: nil)
            let snapshot = try await client.fetch(accountID: accountA, onlyIfTokenChanged: true,
                                                  readToken: { self.token(self.accountA) }, validate: { _ in })
            XCTAssertEqual(snapshot.windows.first?.usedPercent, 23)
        }
    }
}

private actor TokenGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private actor UsageFixtureService {
    let accounts: [String: String]
    let organization: String
    var paths: [String] = []
    var queries: [String?] = []
    private var statuses: [String: Int] = [:]
    private var mismatchedIdentity: String?
    private var retryAfter = "600"
    private var bodyOverride: JSONValue?
    private var profileOverride: JSONValue?
    private var usageStatus: Int?
    private var usageBody: JSONValue?
    func setUsageStatus(_ value: Int) { usageStatus = value }
    func setUsageBody(_ value: JSONValue) { usageBody = value }
    func setRetryAfter(_ value: String) { retryAfter = value }
    func setBody(_ value: JSONValue?) { bodyOverride = value }
    func setProfile(_ value: JSONValue) { profileOverride = value }
    init(accounts: [String: String], organization: String) { self.accounts = accounts; self.organization = organization }
    func reject(_ account: String, status: Int?) { statuses[account] = status }
    func mismatch(_ value: String) { mismatchedIdentity = value }
    func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.host == "api.anthropic.com", request.httpMethod == "GET",
              let auth = request.value(forHTTPHeaderField: "Authorization"), auth.hasPrefix("Bearer "),
              let account = accounts[String(auth.dropFirst(7))] else { throw SwitchError.changed }
        paths.append(url.path)
        queries.append(url.query)
        let status = statuses[account] ?? (url.path.hasSuffix("/usage") ? usageStatus : nil) ?? 200
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Retry-After": retryAfter])!
        let body: JSONValue
        if url.path.hasSuffix("/profile") {
            body = profileOverride ?? .object([
                "account": .object(["uuid": .string(mismatchedIdentity == organization ? account : mismatchedIdentity ?? account)]),
                "organization": .object(["uuid": .string(mismatchedIdentity == organization ? account : organization)])
            ])
        } else {
            body = usageBody ?? .object(["five_hour": .object(["utilization": .number(23)])])
        }
        return (try JSONEncoder().encode(bodyOverride ?? body), response)
    }
}

private final class FixtureClock {
    var date = Date()
    func advance(_ interval: TimeInterval) { date.addTimeInterval(interval) }
}
