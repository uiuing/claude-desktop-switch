import Foundation
import XCTest
@testable import SwitchMac

final class SessionTransferRecordTests: XCTestCase {
    private func transfer(_ source: [String: Any]) throws -> NSDictionary {
        let data = try SessionTransferRecord.data(from: source)
        let value = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(value as? NSDictionary)
    }

    func testNativeMcpCatalogArraysAndEmptyCatalogsArePreserved() throws {
        for json in [#"{"remoteMcpServersConfig":[]}"#,
                     #"{"remoteMcpServersConfig":[{"uuid":"fixture-server","name":"Fixture","url":"https://fixture.invalid/mcp","tools":[],"futureMetadata":{"enabled":true}}]}"#] {
            let source = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            XCTAssertEqual(try transfer(source), source as NSDictionary)
        }
    }

    func testNativeOptionalNullsAndAbsentFieldsDoNotBlockTransfer() throws {
        let source: [String: Any] = ["sessionPermissionUpdates": NSNull(), "remoteMcpServersConfig": NSNull(),
                                    "sshConfig": NSNull(), "futureSetting": true]
        XCTAssertEqual(try transfer(source), source as NSDictionary)
        XCTAssertEqual(try transfer([:]), NSDictionary())
    }

    func testCatalogCredentialsAreRemovedWithoutChangingToolSchemaDefinitions() throws {
        let schema: [String: Any] = ["type": "object", "properties": [
            "token": ["type": "string", "description": "A term in the task being analyzed"],
            "password": ["type": "string"], "Authorization": ["type": "boolean"]],
            "required": ["token"], "futureSchemaMetadata": ["opaque": true]]
        let tool: [String: Any] = ["name": "analyze_terms", "inputSchema": schema, "outputSchema": schema]
        let metadata: [String: Any] = ["uuid": "fixture-server", "name": "Fixture", "tools": [tool],
                                       "futureSetting": ["enabled": true]]
        var server = metadata
        server["headers"] = ["Authorization": "synthetic-credential", "Accept": "application/json"]
        let transferred = try transfer(["remoteMcpServersConfig": [server]])
        var expected = metadata; expected["headers"] = ["Accept": "application/json"]
        XCTAssertEqual(transferred, ["remoteMcpServersConfig": [expected]] as NSDictionary)
    }

    func testMalformedContainersRemainBlocked() {
        for value: Any in [1, "unsupported", [1], ["unsupported"], [NSNull()]] {
            XCTAssertThrowsError(try transfer(["remoteMcpServersConfig": value]))
        }
        XCTAssertThrowsError(try transfer(["sshConfig": []]))
    }

    func testFutureMetadataAndAllNonCredentialContainersStayIntact() throws {
        var source: [String: Any] = [
            "permissionMode": "future-mode", "autoChosenInApp": true, "bypassChosenInApp": false,
            "sessionSettings": ["outputStyle": "concise", "futureSetting": ["enabled": true]],
            "prs": [["number": 17, "branch": "feature"]], "title": NSNull(),
            "worktreePath": "/fixture/worktrees/feature", "sshConfig": ["host": "fixture-host"],
            "pendingFirstStart": ["task": "Original task", "options": ["remoteControlAtStart": true, "futureOption": true]],
            "publishedArtifacts": [["url": "https://claude.ai/code/frame/fixture", "sourcePath": "/fixture/result.pdf"]],
            "cloudSpawnedTasks": [["taskId": "fixture", "prompt": "Original child task"]],
            "backgroundTaskSuggestions": [["target": "cloud", "acceptedPicks": ["cloudPoolId": "fixture"]]],
            "resolvedBackgroundTaskSuggestions": ["fixture": "started"],
            "movedToCloud": ["cloudSessionId": "fixture"], "spaceId": "fixture", "scheduledTaskId": "fixture",
            "armedWorkAtQuit": ["cronCount": 1], "violinBowPrompts": ["Unabridged task"],
            "enabledMcpTools": ["fixture-tool"], "withheldConnectorHosts": ["fixture-host"]
        ]
        for index in 0..<50 {
            source["futureField\(index)"] = ["values": [1, 2, 3], "unknown": ["token": "task metadata", "enabled": true]]
        }
        XCTAssertEqual(try transfer(source), source as NSDictionary)
    }

    func testIdentityAndAuthorityAreRemovedWithoutErasingConnectorMetadata() throws {
        let source: [String: Any] = [
            "permissionMode": "auto", "emailAddress": "synthetic", "accessToken": "synthetic-credential", "accountUUID": "synthetic",
            "sshRemoteProcessId": 123, "bridgeSessionIds": ["synthetic"],
            "sshConfig": ["host": "fixture-host", "port": 22, "identityFile": "/fixture/private-key", "privateKey": "synthetic-private-key"],
            "chromePermissionMode": "skip_all_permission_checks", "alwaysAllowedReasons": ["synthetic"],
            "remoteMcpServersConfig": ["fixture": ["url": "https://fixture.invalid/mcp", "futureOption": true,
                "headers": ["Authorization": "synthetic-credential", "X-API-Key": "synthetic-credential", "Accept": "application/json"],
                "env": ["SERVICE_API_KEY": "synthetic-credential", "TRANSPORT_VERSION": "2", "bearerToken": "synthetic-credential",
                         "SSH_AUTH_SOCK": "synthetic-socket"]]]
        ]
        let expected: [String: Any] = ["permissionMode": "auto", "sshConfig": ["host": "fixture-host", "port": 22], "remoteMcpServersConfig": ["fixture": [
            "url": "https://fixture.invalid/mcp", "futureOption": true, "headers": ["Accept": "application/json"],
            "env": ["TRANSPORT_VERSION": "2"]]]]
        XCTAssertEqual(try transfer(source), expected as NSDictionary)
    }

    func testDirectoryIntentSurvivesWhileToolGrantsDoNot() throws {
        let directory: [String: Any] = ["type": "addDirectories", "directories": ["/fixture/files"],
                                         "destination": "session", "futureMetadata": ["source": "person"]]
        let removal: [String: Any] = ["type": "removeDirectories", "directories": ["/fixture/old"], "destination": "session"]
        let source: [String: Any] = ["sessionPermissionUpdates": [directory,
            ["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "*"]]], removal]]
        XCTAssertEqual(try transfer(source), ["sessionPermissionUpdates": [directory, removal]] as NSDictionary)
    }

    func testUnknownAuthorizationFormatStopsInsteadOfDroppingOrGrantingIt() {
        for updates: Any in ["unsupported", [["type": "futureGrant", "anything": true]],
                             [["type": "addDirectories", "directories": ["relative"]]]] {
            XCTAssertThrowsError(try transfer(["sessionPermissionUpdates": updates]))
        }
        for url in ["https://fixture-user:fixture-password@fixture.invalid/mcp", "https://fixture.invalid/mcp?access_token=synthetic"] {
            XCTAssertThrowsError(try transfer(["remoteMcpServersConfig": ["fixture": ["url": url]]]))
            XCTAssertThrowsError(try transfer(["remoteMcpServersConfig": [["uuid": "fixture-server", "name": "Fixture", "url": url, "tools": []]]]))
        }
    }

    func testCredentialWordsInTaskContentAreNotRedacted() throws {
        let source: [String: Any] = ["futureTask": ["token": "token budgeting task", "authorization": "document this concept"],
                                    "title": "Explain accessToken", "prompt": "Do not replace historical content", "futureRenderToken": "ordinary opaque metadata"]
        XCTAssertEqual(try transfer(source), source as NSDictionary)
    }

    func testLargeIntegerMetadataKeepsPrecision() throws {
        let source = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"{"futureCounter":9007199254740993,"nested":{"counter":18446744073709551615}}"#.utf8)) as? [String: Any])
        let transferred = try XCTUnwrap(try transfer(source) as? [String: Any])
        XCTAssertNil(transferred["permissionMode"])
        XCTAssertEqual((transferred["futureCounter"] as? NSNumber)?.uint64Value, 9_007_199_254_740_993)
        XCTAssertEqual(((transferred["nested"] as? [String: Any])?["counter"] as? NSNumber)?.uint64Value, UInt64.max)
    }

    func testLineageAndPendingResultsRemainUnchanged() throws {
        let source: [String: Any] = ["spawnedFrom": ["sessionId": "fixture-parent", "taskId": "fixture-task", "sharedCheckout": true],
            "forkedFromSessionId": "fixture-parent", "dispatchParentId": "fixture-parent", "dispatchParentOrigin": "future-origin",
            "priorCliSessionIds": ["fixture-history"], "sideSessionNotes": ["Full result"],
            "queuedSideSessionNotes": [["id": "fixture-note", "text": "Unacknowledged result"]]]
        XCTAssertEqual(try transfer(source), source as NSDictionary)
    }

    func testExplicitCredentialsAreExcludedFromNestedMetadataWithoutScrubbingOrdinaryTokens() throws {
        let source: [String: Any] = ["bearerToken": "synthetic-credential", "renderToken": "ordinary-render-id",
            "connectionSettings": ["auth": ["accessToken": "synthetic-credential", "token": "synthetic-credential"]],
            "nested": ["authorization": "Bearer synthetic-credential"],
            "futureTask": ["token": "token budgeting", "authorization": "document this concept"],
            "draft": ["parameters": ["password": "historical example"]]]
        let result = try transfer(source)
        XCTAssertNil(result["bearerToken"])
        XCTAssertEqual(result["renderToken"] as? String, "ordinary-render-id")
        XCTAssertEqual(result["connectionSettings"] as? NSDictionary, ["auth": [:]] as NSDictionary)
        XCTAssertEqual(result["nested"] as? NSDictionary, NSDictionary())
        XCTAssertEqual(result["futureTask"] as? NSDictionary, source["futureTask"] as? NSDictionary)
        XCTAssertEqual(result["draft"] as? NSDictionary, source["draft"] as? NSDictionary)
    }

    func testHeaderPairsAreFilteredAndAuthCannotHideBehindASchemaField() throws {
        for headers: Any in [[["name": "Authorization", "value": "synthetic-credential"], ["name": "Accept", "value": "application/json"]],
                             [["Authorization", "synthetic-credential"], ["Accept", "application/json"]]] {
            let result = try transfer(["remoteMcpServersConfig": [["uuid": "fixture", "name": "Fixture", "tools": [], "headers": headers]]])
            let catalog = try XCTUnwrap(result["remoteMcpServersConfig"] as? [[String: Any]])
            XCTAssertEqual((catalog[0]["headers"] as? [Any])?.count, 1)
            XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self).contains("synthetic-credential"))
        }
        let result = try SessionTransferRecord.withoutCredentials(["auth": ["inputSchema": ["token": "synthetic-credential"]]])
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self).contains("synthetic-credential"))
    }

    func testSignedAndGenericKeyConnectorURLsRequireReauthorization() {
        for query in ["key=synthetic", "sig=synthetic", "X-Amz-Signature=synthetic", "X-Goog-Signature=synthetic"] {
            XCTAssertThrowsError(try transfer(["remoteMcpServersConfig": [["uuid": "fixture", "name": "Fixture", "tools": [],
                "url": "https://fixture.invalid/mcp?" + query]]]))
        }
    }
}
