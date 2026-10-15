import Foundation

enum SessionTransferRecord {
    // Account authorization and live connection state must not follow an index into another account.
    // All other fields, including new fields and nested settings, remain owned by Claude.
    static let excludedFields: Set<String> = [
        "enabledMcpTools", "remoteMcpServersConfig", "withheldConnectorHosts", "emailAddress", "envScopeId",
        "startedFromEnvironmentId", "bridgeSessionIds", "cloudSessionId", "remoteControl", "remoteControlSpawn",
        "remoteControlAutoEligible", "remoteControlUserEnabled", "remoteControlLiveAtUpdateQuit",
        "chromePermissionMode", "chromeAllowedDomains", "chromeTabGroupId", "cuAllowedApps", "cuGrantFlags",
        "cuFlagsGrantedAt", "cuLastScreenshotDims", "alwaysAllowedReasons",
        "sessionPermissionUpdates", "sshRemoteProcessId", "sshReattach", "sshKillRecoveryGrantedAt",
        "sshForeignDaemonLossAt", "sshProcessLossStoodDownAt", "cutTurnStoppedAt", "lastSpawnRootDetected",
        "cliMcpAppServerNames", "movedToCloud", "cloudSpawnedTasks", "spaceId", "scheduledTaskId",
        "scheduledRunContinued", "publishedArtifacts", "armedWorkAtQuit", "remoteControlDescendant",
        "steeredByRemoteClient", "violinBow", "violinBowHomeSettings", "violinBowHomeSettingsCli",
        "violinBowPrompts", "violinBowPromptKinds"
    ]

    static func data(from record: [String: Any]) throws -> Data {
        var transferred = record
        for field in excludedFields { transferred.removeValue(forKey: field) }
        if record["dispatchParentOrigin"] as? String != "local" {
            transferred.removeValue(forKey: "dispatchParentId")
            transferred.removeValue(forKey: "dispatchParentOrigin")
        }
        if var pending = record["pendingFirstStart"] as? [String: Any],
           var options = pending["options"] as? [String: Any] {
            options.removeValue(forKey: "remoteControlAtStart")
            pending["options"] = options; transferred["pendingFirstStart"] = pending
        }
        var removedTasks = Set((record["cloudSpawnedTasks"] as? [[String: Any]] ?? []).compactMap { $0["taskId"] as? String })
        if let suggestions = record["backgroundTaskSuggestions"] as? [Any] {
            transferred["backgroundTaskSuggestions"] = suggestions.compactMap { value -> Any? in
                guard var suggestion = value as? [String: Any] else { return value }
                let picks = suggestion["acceptedPicks"] as? [String: Any]
                if isCloudSuggestion(suggestion, picks: picks) {
                    if let id = suggestion["id"] as? String { removedTasks.insert(id) }
                    return nil
                }
                // Only these unused choices belong to cloud accounts; arbitrary nested metadata stays intact.
                for field in cloudChoices { suggestion.removeValue(forKey: field) }
                if var picks {
                    for field in cloudChoices { picks.removeValue(forKey: field) }
                    suggestion["acceptedPicks"] = picks
                }
                return suggestion
            }
        }
        if var resolved = record["resolvedBackgroundTaskSuggestions"] as? [String: Any] {
            for id in removedTasks { resolved.removeValue(forKey: id) }
            transferred["resolvedBackgroundTaskSuggestions"] = resolved
        }
        return try JSONSerialization.data(withJSONObject: transferred, options: .sortedKeys)
    }

    private static let cloudChoices = ["cloudEnvironmentId", "cloudPoolId"]
    private static func isCloudSuggestion(_ suggestion: [String: Any], picks: [String: Any]?) -> Bool {
        if suggestion["target"] as? String == "cloud" || suggestion["autoStart"] as? String == "cloud" || picks?["target"] as? String == "cloud" {
            return true
        }
        if suggestion["target"] as? String == "local" || picks?["target"] as? String == "local" { return false }
        return cloudChoices.contains { field in
            [suggestion[field], picks?[field]].contains { value in value != nil && !(value is NSNull) }
        }
    }
}
