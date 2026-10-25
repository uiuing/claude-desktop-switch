import SwitchCore

/// Completion describes the applied change; checking Claude remains a user action.
struct OperationFeedback {
    var title: String
    var body: String
    var notificationBody: String
    enum Style { case success, warning, failure }
    var style: Style
    var text: String { title + "\n" + body }
    var requiresAttention: Bool { style != .success }

    static func completed(plan: OperationPlan, target: String, quota: [QuotaReadout], result: OperationResult) -> Self {
        let title: String
        var lines: [String] = []
        switch plan.kind {
        case .switchAccount:
            title = L10n.tr("Account switched")
            lines.append(L10n.tr("Switched to {0}.", L10n.argument(target)))
        case .migrate: title = L10n.tr("Conversations ready")
        case .capture:
            title = L10n.tr("Account saved")
            lines.append(L10n.tr("Saved {0}.", L10n.argument(target)))
        case .signOut:
            title = L10n.tr("Ready to add an account")
            lines.append(L10n.tr("Saved {0}. Sign in to another account in Claude.", L10n.argument(target)))
        case .recover: title = L10n.tr("Recovery complete")
        }
        if plan.kind == .switchAccount || plan.kind == .migrate {
            let count = plan.transferSessions.map { ConversationTree($0).roots.count } ?? plan.conversationIDs.count
            if count > 0 { lines.append(L10n.tr("Conversations ready in {0}: {1}.", L10n.argument(target), L10n.argument(count))) }
            if plan.kind == .switchAccount {
                let readings = quota.filter { $0.state == .recorded && $0.origin == .live && $0.remainingPercent != nil }
                if readings.isEmpty { lines.append(L10n.tr("Quota not available yet.")) }
                else {
                    lines.append(readings.map { L10n.tr("{0} remaining: {1}", L10n.argument($0.shortTitle), $0.percentageText) }.joined(separator: " · "))
                }
            }
            if !result.needsManualOpen { lines.append(L10n.tr("Please check in Claude.")) }
        }
        if result.needsManualOpen { lines.append(L10n.tr("Claude could not reopen. Open it manually to check.")) }
        if result.backupIncomplete { lines.append(L10n.tr("The recovery backup could not be completed. Your data has been kept.")) }
        let body = lines.joined(separator: "\n")
        return .init(title: title, body: body, notificationBody: body,
                     style: result.needsManualOpen || result.backupIncomplete ? .warning : .success)
    }

    static func failed(kind: OperationKind, target: String, reason: String) -> Self {
        let title: String
        switch kind {
        case .switchAccount: title = L10n.tr("Account switch failed")
        case .migrate: title = L10n.tr("Conversation transfer failed")
        case .capture: title = L10n.tr("Could not save account")
        case .signOut: title = L10n.tr("Could not add account")
        case .recover: title = L10n.tr("Recovery failed")
        }
        // System notifications show the selected account, but not raw errors that may contain file paths.
        let summary = L10n.tr("Account: {0}. Open Claude Switch for details.", L10n.argument(target))
        return .init(title: title, body: target + "\n" + reason, notificationBody: summary, style: .failure)
    }
}
