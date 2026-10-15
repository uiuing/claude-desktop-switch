import Foundation
import SwitchCore

extension AppState {
    var newAccountFollowTarget: Account? {
        guard let target = library.newAccountFollowUp?.targetAccountID, target == activeID else { return nil }
        return activeAccount
    }
    var newAccountFollowSessions: [Conversation] {
        guard let followUp = library.newAccountFollowUp, let target = followUp.targetAccountID else { return [] }
        return SessionLibrary.followedSessions(inventory?.conversations ?? [], rules: library.follows,
            activeAccountID: followUp.sourceAccountID, targetAccountID: target)
    }
    var newAccountFollowNeedsOrganization: Bool {
        guard let target = newAccountFollowTarget else { return true }
        return target.organizationID == nil || target.organizationVerifiedAt == nil
    }
    var showsNewAccountFollowUp: Bool { newAccountFollowTarget != nil && !newAccountFollowSessions.isEmpty }

    func beginNewAccountFollowUp(sourceAccountID: String?) {
        // Preserve an in-progress add flow when its sign-in screen is opened again.
        if sourceAccountID == nil, library.newAccountFollowUp?.targetAccountID == nil,
           library.newAccountFollowUp != nil { return }
        library.newAccountFollowUp = library.follows.isEmpty ? nil : NewAccountFollowUp(sourceAccountID: sourceAccountID)
        newAccountFollowError = nil
        persist()
    }
    /// Called only after discovery verifies the signed-in account and its saved credential fingerprint.
    func acceptNewAccountLogin(_ account: Account) async {
        guard var followUp = library.newAccountFollowUp, followUp.targetAccountID == nil,
              account.hasSnapshot, activeID == account.id, inventory?.signedIn == true else { return }
        if followUp.sourceAccountID == account.id { library.newAccountFollowUp = nil }
        else { followUp.targetAccountID = account.id; library.newAccountFollowUp = followUp }
        persist()
        await advanceNewAccountFollowUp()
    }
    func advanceNewAccountFollowUp() async {
        guard let followUp = library.newAccountFollowUp, let target = followUp.targetAccountID,
              inventory?.signedIn == true, let activeID else { return }
        guard activeID == target else {
            library.newAccountFollowUp = nil; newAccountFollowError = nil; persist()
            return
        }
        if newAccountFollowSessions.isEmpty {
            library.newAccountFollowUp = nil; newAccountFollowError = nil; persist()
            return
        }
        guard !followUp.reviewOffered else { return }
        await reviewNewAccountFollowUp()
    }
    func reviewNewAccountFollowUp() async {
        guard startupAccess.isReady, !working, !preparingNewAccountFollowUp, pending == nil,
              !showAddAccount, !showQuickFind, recoveryIDs.isEmpty, inventory?.signedIn == true,
              let followUp = library.newAccountFollowUp, let target = newAccountFollowTarget,
              !newAccountFollowNeedsOrganization else { return }
        let sessions = newAccountFollowSessions
        guard !sessions.isEmpty else { return }
        preparingNewAccountFollowUp = true
        defer { preparingNewAccountFollowUp = false }
        library.newAccountFollowUp?.reviewOffered = true
        newAccountFollowError = nil
        persist()
        do {
            var operation = try await makeOperation(.migrate, target: target, sessions: sessions)
            // A profile read or another operation can finish while the preview is being prepared.
            guard library.newAccountFollowUp?.id == followUp.id, activeID == target.id,
                  newAccountFollowTarget?.organizationID == target.organizationID,
                  inventory?.signedIn == true, !working, pending == nil, !showAddAccount, !showQuickFind else { return }
            operation.newAccountFollowUpID = followUp.id
            pending = operation
            message = nil
            page = .accounts
            if !demo { presentWorkbench?() }
        } catch {
            guard library.newAccountFollowUp?.id == followUp.id else { return }
            newAccountFollowError = display(error)
        }
    }
    /// A canceled preview leaves a review entry; only a successful matching transfer clears it.
    func completeNewAccountFollowUp(_ operation: PendingOperation) {
        guard let id = operation.newAccountFollowUpID, library.newAccountFollowUp?.id == id,
              operation.plan.kind == .migrate else { return }
        library.newAccountFollowUp = nil; newAccountFollowError = nil
    }
}
