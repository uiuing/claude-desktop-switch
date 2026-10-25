import Foundation
import SwitchCore

extension AppState {
    func makeSwitchOperation(target: Account, followed: [Conversation]) async throws -> PendingOperation {
        // An invalid followed record must remain deselectable in the confirmation.
        var operation = try await makeOperation(.switchAccount, target: target, sessions: [])
        let now = Date(), followedIDs = Set(followed.map { conversationTree.root(of: $0).id })
        operation.followCandidates = SessionLibrary.switchCandidates(inventory?.conversations ?? [], followed: followed,
                                                                     activeAccountID: operation.plan.sourceAccountID, now: now)
        operation.sessions = (operation.followCandidates ?? []).filter {
            followedIDs.contains($0.id) || conversationTree.recentlyActive($0, accountID: operation.plan.sourceAccountID, now: now)
        }
        operation.initialFollowIDs = followedIDs
        return await prepareSwitchSelection(operation)
    }

    func setPendingFollow(_ selected: Bool, sessionID: String) async {
        guard !working, var operation = pending, !operation.preparingSelection,
              let candidates = operation.followCandidates, candidates.contains(where: { $0.id == sessionID }) else { return }
        var ids = Set(operation.sessions.map(\.id))
        if selected { ids.insert(sessionID) } else { ids.remove(sessionID) }
        operation.sessions = candidates.filter { ids.contains($0.id) }
        operation.preparingSelection = true
        operation.selectionError = nil
        pending = operation
        let prepared = await prepareSwitchSelection(operation)
        guard pending?.id == operation.id, !working else { return }
        pending = prepared
    }

    private func prepareSwitchSelection(_ draft: PendingOperation) async -> PendingOperation {
        var operation = draft
        do {
            var prepared = try await makeOperation(.switchAccount, target: operation.target, sessions: operation.sessions)
            guard prepared.plan.sourceAccountID == operation.plan.sourceAccountID else { throw SwitchError.changed }
            prepared.plan.id = operation.id
            operation.plan = prepared.plan
            operation.sessions = prepared.sessions
            operation.selectionError = nil
        } catch { operation.selectionError = display(error) }
        operation.preparingSelection = false
        return operation
    }

    /// Called only after the switch commits; canceling or failing leaves saved rules untouched.
    func applySwitchFollowSelection(_ operation: PendingOperation) {
        guard operation.plan.kind == .switchAccount, let candidates = operation.followCandidates else { return }
        let selected = Set(operation.sessions.map(\.id))
        for session in candidates {
            let members = conversationTree.members(of: session)
            let rules = library.follows.filter { rule in members.contains(where: rule.matches) }
            library.follows.removeAll { rule in members.contains(where: rule.matches) }
            guard selected.contains(session.id) else { continue }
            let allAccounts = rules.isEmpty || rules.contains { $0.mode == .allSavedAccounts }
            let targets = Set(rules.flatMap(\.targetAccountIDs)).union([operation.target.id]).sorted()
            library.follows.append(FollowRule(conversationID: session.id, sessionID: session.sessionID,
                mode: allAccounts ? .allSavedAccounts : .selectedAccounts, targetAccountIDs: allAccounts ? [] : targets))
        }
    }
}
