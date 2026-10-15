import SwiftUI
import SwitchCore

struct NewAccountFollowUpStatus: View {
    @Environment(AppState.self) private var state
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.tr("Login saved · Conversations not transferred"), systemImage: "bubble.left.and.text.bubble.right")
                .font(.system(size: 13, weight: .medium))
            if state.newAccountFollowNeedsOrganization {
                Text(L10n.tr("Waiting to confirm this account's organization. Refresh its quota if this takes too long."))
                if let account = state.newAccountFollowTarget {
                    Button(L10n.tr("Refresh quota")) { Task { await state.refreshNow(accountID: account.id) } }
                        .disabled(state.demo || state.working || state.usageRefreshingAccountID != nil)
                }
            } else {
                Text(L10n.tr("Review {0} followed conversations and their move or copy settings. Claude will restart only after you confirm the transfer.",
                             L10n.argument(state.newAccountFollowSessions.count)))
                if let error = state.newAccountFollowError {
                    Text(L10n.tr("Could not prepare the transfer: {0}", L10n.argument(error))).foregroundStyle(.orange)
                }
                Button(L10n.tr("Review transfer")) { Task { await state.reviewNewAccountFollowUp() } }
                    .disabled(state.working || state.preparingNewAccountFollowUp || state.pending != nil || !state.recoveryIDs.isEmpty)
            }
        }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
    }
}
