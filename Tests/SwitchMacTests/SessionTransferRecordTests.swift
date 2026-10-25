import Foundation
import XCTest
@testable import SwitchMac

final class SessionTransferRecordTests: XCTestCase {
    private func transfer(_ source: [String: Any]) throws -> NSDictionary {
        let data = try SessionTransferRecord.data(from: source)
        let value = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(value as? NSDictionary)
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
}
