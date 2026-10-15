import Foundation
import XCTest
@testable import SwitchMac

final class SessionTransferRecordTests: XCTestCase {
    func testNewFieldsNestedSettingsAndFutureModesArePreserved() throws {
        let source: [String: Any] = [
            "permissionMode": "future-mode", "autoChosenInApp": true, "bypassChosenInApp": false,
            "sessionSettings": ["outputStyle": "concise", "futureSetting": ["enabled": true]],
            "futureField": ["values": [1, 2, 3], "nested": ["value": "fixture"]],
            "prs": [["number": 17, "branch": "feature"]], "pendingFirstStart": ["futureOption": true],
            "sshConfig": ["host": "fixture-host"], "worktreePath": "/fixture/worktrees/feature",
            "title": NSNull()
        ]
        let transferred = try XCTUnwrap(JSONSerialization.jsonObject(with: SessionTransferRecord.data(from: source)) as? NSDictionary)
        XCTAssertEqual(transferred, source as NSDictionary)
    }

    func testAuthorizationAndConnectionFieldsAreExcludedWithoutChangingMode() throws {
        let source: [String: Any] = [
            "permissionMode": "auto", "autoChosenInApp": true,
            "remoteMcpServersConfig": ["fixture": ["authorization": "synthetic"]],
            "sessionPermissionUpdates": [["type": "addRules"]], "alwaysAllowedReasons": ["fixture"],
            "emailAddress": "synthetic", "cloudSessionId": "synthetic", "sshRemoteProcessId": 123,
            "remoteControl": true, "remoteControlUserEnabled": true, "chromePermissionMode": "skip_all_permission_checks"
        ]
        let transferred = try XCTUnwrap(JSONSerialization.jsonObject(with: SessionTransferRecord.data(from: source)) as? NSDictionary)
        XCTAssertEqual(transferred, ["permissionMode": "auto", "autoChosenInApp": true] as NSDictionary)
    }

    func testMissingModeStaysMissingAndLargeIntegerMetadataKeepsPrecision() throws {
        let source = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"{"futureCounter":9007199254740993,"nested":{"counter":18446744073709551615}}"#.utf8)) as? [String: Any])
        let data = try SessionTransferRecord.data(from: source)
        let transferred = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(transferred["permissionMode"])
        XCTAssertEqual((transferred["futureCounter"] as? NSNumber)?.uint64Value, 9_007_199_254_740_993)
        XCTAssertEqual(((transferred["nested"] as? [String: Any])?["counter"] as? NSNumber)?.uint64Value, UInt64.max)
    }

    func testCloudContainersAndNestedRemoteControlIntentAreRemoved() throws {
        let source: [String: Any] = [
            "permissionMode": "auto", "autoChosenInApp": true,
            "movedToCloud": ["cloudSessionId": "cloud-session-fixture"],
            "cloudSpawnedTasks": [["taskId": "cloud-task-fixture", "sessionId": "cloud-session-fixture"]],
            "spaceId": "space-fixture", "scheduledTaskId": "routine-fixture", "scheduledRunContinued": true,
            "dispatchParentId": "remote-parent-fixture", "dispatchParentOrigin": "remote",
            "publishedArtifacts": [["url": "cloud-artifact-fixture", "sourcePath": "/fixture/result.pdf"]],
            "remoteControlDescendant": true, "steeredByRemoteClient": true, "armedWorkAtQuit": ["cronCount": 1],
            "violinBow": true, "violinBowHomeSettings": ["fixture": true], "violinBowPrompts": ["fixture"],
            "pendingFirstStart": ["permissionMode": "auto", "task": "Local fixture task", "options": [
                "remoteControlAtStart": true, "useWorktree": true, "futureLocalOption": "kept"]]
        ]
        let transferred = try XCTUnwrap(JSONSerialization.jsonObject(with: SessionTransferRecord.data(from: source)) as? [String: Any])
        XCTAssertEqual(Set(transferred.keys), ["permissionMode", "autoChosenInApp", "pendingFirstStart"])
        let pending = try XCTUnwrap(transferred["pendingFirstStart"] as? [String: Any])
        XCTAssertEqual(pending["task"] as? String, "Local fixture task")
        XCTAssertEqual(pending["permissionMode"] as? String, "auto")
        XCTAssertEqual(pending["options"] as? NSDictionary, ["useWorktree": true, "futureLocalOption": "kept"] as NSDictionary)
    }

    func testCloudSuggestionsAreRemovedWithoutLosingLocalSuggestionsOrTheirResults() throws {
        let source: [String: Any] = [
            "backgroundTaskSuggestions": [
                ["id": "cloud", "target": "cloud", "prompt": "Cloud fixture task"],
                ["id": "automatic", "autoStart": "cloud"],
                ["id": "implicit", "cloudEnvironmentId": "env-fixture"],
                ["id": "picked", "target": "local", "acceptedPicks": ["target": "cloud", "cloudPoolId": "pool-fixture"]],
                ["id": "local", "target": "local", "prompt": "Local fixture task", "useWorktree": true,
                 "cloudEnvironmentId": "unused-env", "acceptedPicks": ["target": "local", "cloudPoolId": "unused-pool", "effort": "high"]],
                ["id": "future", "futureLocalOption": ["keep": true]]
            ],
            "cloudSpawnedTasks": [["taskId": "old-cloud", "sessionId": "cloud-session-fixture"]],
            "resolvedBackgroundTaskSuggestions": ["cloud": "started", "old-cloud": "started_notified", "local": "dismissed"]
        ]
        let transferred = try XCTUnwrap(JSONSerialization.jsonObject(with: SessionTransferRecord.data(from: source)) as? [String: Any])
        let suggestions = try XCTUnwrap(transferred["backgroundTaskSuggestions"] as? [[String: Any]])
        XCTAssertEqual(suggestions.compactMap { $0["id"] as? String }, ["local", "future"])
        XCTAssertEqual(suggestions[0]["prompt"] as? String, "Local fixture task")
        XCTAssertEqual(suggestions[0]["useWorktree"] as? Bool, true)
        XCTAssertNil(suggestions[0]["cloudEnvironmentId"])
        XCTAssertEqual(suggestions[0]["acceptedPicks"] as? NSDictionary, ["target": "local", "effort": "high"] as NSDictionary)
        XCTAssertEqual(transferred["resolvedBackgroundTaskSuggestions"] as? NSDictionary, ["local": "dismissed"] as NSDictionary)
    }

    func testLocalLineageExecutionTargetsAndDisplayPreferenceStayIntact() throws {
        let source: [String: Any] = [
            "dispatchParentId": "local-parent-fixture", "dispatchParentOrigin": "local",
            "spawnedFrom": ["sessionId": "local-parent-fixture", "taskId": "local-task-fixture", "sharedCheckout": true],
            "forkedFromSessionId": "local-parent-fixture", "priorCliSessionIds": ["local-history-fixture"],
            "sshConfig": ["host": "fixture-host"], "wslConfig": ["distro": "fixture-distro"],
            "cuSelectedDisplayId": 7, "prs": [["number": 17]], "spaceInTitle": "cloud account fixture"
        ]
        let transferred = try XCTUnwrap(JSONSerialization.jsonObject(with: SessionTransferRecord.data(from: source)) as? NSDictionary)
        XCTAssertEqual(transferred, source as NSDictionary)
    }

    func testOnlyExplicitLocalDispatchAncestrySurvives() throws {
        for origin in [nil, "remote", "future-origin", "local"] {
            var source: [String: Any] = ["dispatchParentId": "parent-fixture", "futureTask": ["target": "cloud"]]
            source["dispatchParentOrigin"] = origin
            let transferred = try XCTUnwrap(JSONSerialization.jsonObject(with: SessionTransferRecord.data(from: source)) as? [String: Any])
            XCTAssertEqual(transferred["dispatchParentId"] as? String, origin == "local" ? "parent-fixture" : nil)
            XCTAssertEqual(transferred["dispatchParentOrigin"] as? String, origin == "local" ? "local" : nil)
            XCTAssertEqual(transferred["futureTask"] as? NSDictionary, source["futureTask"] as? NSDictionary)
        }
    }

    func testMixedSuggestionValuesDoNotHideKnownCloudTasksOrEraseOpaqueMetadata() throws {
        let source: [String: Any] = [
            "backgroundTaskSuggestions": [
                "future-value", NSNull(),
                ["id": "cloud", "acceptedPicks": ["cloudPoolId": "pool-fixture"]],
                ["id": "local", "acceptedPicks": ["target": "local", "cloudPoolId": "unused-pool"],
                 "futureMetadata": ["target": "cloud", "cloudEnvironmentId": "opaque-fixture"]],
                ["id": "future", "cloudEnvironmentId": NSNull()]
            ],
            "resolvedBackgroundTaskSuggestions": ["cloud": "started", "local": "dismissed", "unrelated": ["future": true]]
        ]
        let transferred = try XCTUnwrap(JSONSerialization.jsonObject(with: SessionTransferRecord.data(from: source)) as? [String: Any])
        let suggestions = try XCTUnwrap(transferred["backgroundTaskSuggestions"] as? [Any])
        XCTAssertEqual(suggestions.count, 4)
        XCTAssertEqual(suggestions[0] as? String, "future-value")
        XCTAssertTrue(suggestions[1] is NSNull)
        let local = try XCTUnwrap(suggestions[2] as? [String: Any])
        XCTAssertEqual(local["acceptedPicks"] as? NSDictionary, ["target": "local"] as NSDictionary)
        XCTAssertEqual(local["futureMetadata"] as? NSDictionary, ["target": "cloud", "cloudEnvironmentId": "opaque-fixture"] as NSDictionary)
        XCTAssertEqual((suggestions[3] as? [String: Any])?["id"] as? String, "future")
        XCTAssertEqual(transferred["resolvedBackgroundTaskSuggestions"] as? NSDictionary,
                       ["local": "dismissed", "unrelated": ["future": true]] as NSDictionary)
    }
}
