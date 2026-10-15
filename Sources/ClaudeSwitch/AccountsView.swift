import SwiftUI
import SwitchCore

struct AccountsView: View {
    @Environment(AppState.self) private var state
    @State private var discarding: String?
    var body: some View {
        Group {
            if state.accounts.isEmpty && !state.activeUnsaved && state.recoverableLogins.isEmpty && !state.claudeSignedOut {
                ContentUnavailableView {
                    Label(L10n.tr("No accounts yet"), systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text(L10n.tr("After signing in to Claude Desktop, the current account is saved here automatically."))
                } actions: {
                    Button(L10n.tr("How to add an account")) { state.showAddAccount = true }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if state.quotaAccessRequired || state.authorizingQuotaAccess {
                            QuotaAccessStatus().padding(16).frame(maxWidth: .infinity, alignment: .leading).card()
                        }
                        if state.claudeSignedOut {
                            Label(L10n.tr("Claude is signed out. Switch to a saved account below, or sign in to an account in Claude and it will be saved."),
                                  systemImage: "person.crop.circle.badge.questionmark")
                                .font(.system(size: 12)).padding(16).frame(maxWidth: .infinity, alignment: .leading).card()
                        }
                        ForEach(state.recoverableLogins, id: \.self) { id in
                            HStack(spacing: 10) {
                                Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(Palette.brand)
                                Text(L10n.tr("A copy of the login of {0} is still available and can be restored.", L10n.argument(state.identity(id: id))))
                                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Button(L10n.tr("Delete"), role: .destructive) { discarding = id }.controlSize(.small).disabled(state.working)
                                Button(L10n.tr("Recover")) { Task { await state.restoreLogin(id) } }
                                    .buttonStyle(.borderedProminent).controlSize(.small).disabled(state.working)
                            }.font(.system(size: 12)).padding(16).frame(maxWidth: .infinity, alignment: .leading).card()
                        }
                        if state.activeUnsaved { LoginSaveStatus().padding(16).frame(maxWidth: .infinity, alignment: .leading).card() }
                        ForEach(state.accounts) { AccountCard(account: $0) }
                    }.padding(24)
                }
            }
        }
        .confirmationDialog(L10n.tr("Delete the login copies of {0}?", L10n.argument(discarding.map { state.identity(id: $0) } ?? "")),
                            isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } })) {
            Button(L10n.tr("Delete"), role: .destructive) {
                if let id = discarding { Task { await state.discardRecoverable(id) } }
                discarding = nil
            }
        } message: {
            Text(L10n.tr("The login Claude Switch saved for this account and every backup copy of it are deleted and cannot be restored. Claude Desktop is not affected."))
        }
        .navigationTitle(L10n.tr("Accounts"))
        .navigationSubtitle(state.accounts.isEmpty ? "" : L10n.tr("Accounts: {0}", L10n.argument(state.accounts.count)))
        .toolbar {
            InventoryToolbar(state: state)
            ToolbarItem(placement: .primaryAction) {
                Button { state.showAddAccount = true } label: { Label(L10n.tr("Add account"), systemImage: "plus") }.help(L10n.tr("Add account"))
            }
        }
    }
}

struct QuotaAccessStatus: View {
    @Environment(AppState.self) private var state
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.tr("Allow Keychain access to update quota."), systemImage: "lock")
                .fixedSize(horizontal: false, vertical: true)
            if state.authorizingQuotaAccess {
                ProgressView().controlSize(.small)
            } else {
                Button(L10n.tr("Allow access")) { Task { await state.authorizeQuotaAccess() } }
                    .controlSize(.small).disabled(state.working || state.usageRefreshingAccountID != nil || state.demo)
            }
        }.font(.system(size: 12))
    }
}

/// Progress or failure of saving the signed-in Claude Desktop login into Switch.
struct LoginSaveStatus: View {
    @Environment(AppState.self) private var state
    var compact = false
    var body: some View {
        HStack(spacing: 10) {
            if let error = state.loginSaveError, !state.savingLogin {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(L10n.tr("Could not save the current login: {0}", L10n.argument(error))).lineLimit(compact ? 2 : 3)
                Spacer(minLength: 8)
                Button(L10n.tr("Retry")) { Task { await state.saveCurrentLogin(retry: true) } }.controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
                Text(L10n.tr("Saving the signed-in account…"))
                Spacer(minLength: 0)
            }
        }.font(.system(size: compact ? 11 : 12))
    }
}

struct AccountCard: View {
    @AppStorage(Format.showResetTimeKey) private var showResetTime = true
    @Environment(AppState.self) private var state
    let account: Account
    @State private var removing = false
    private var active: Bool { account.id == state.activeID }
    private var invalid: Bool { !active && account.loginInvalidAt != nil }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 16) {
                header(now: context.date)
                HStack(alignment: .top, spacing: 28) {
                    ForEach(state.quotaRows(for: account.id, now: context.date)) { row in
                        QuotaGauge(row: row, now: context.date).frame(maxWidth: .infinity)
                    }
                }
                let extras = state.extraQuotaRows(for: account.id, now: context.date)
                if !extras.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(extras) { row in
                            Text("\(row.title) \(row.percentageText)").font(.system(size: 11, weight: .medium)).monospacedDigit()
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .foregroundStyle(row.remainingPercent.map { $0 <= 10 ? Palette.quota($0) : .secondary } ?? .secondary)
                                .background(Color.primary.opacity(0.05), in: Capsule())
                                .help(Format.reset(row, now: context.date, showResetTime: showResetTime))
                        }
                    }
                }
                if state.usageStatus(for: account.id) != nil { UsageErrorLine(accountID: account.id) }
            }
        }
        .padding(18)
        .card(highlighted: active)
        .contextMenu { menuItems }
        .confirmationDialog(L10n.tr("Remove “{0}” from Claude Switch?", L10n.argument(state.identity(account))), isPresented: $removing) {
            Button(L10n.tr("Remove"), role: .destructive) { Task { await state.remove(account) } }
        } message: {
            Text(L10n.tr("The login Claude Switch saved for this account and every backup copy of it are deleted and cannot be restored. Claude Desktop is not affected."))
        }
    }
    private func header(now: Date) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(state.identity(account)).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    if let plan = account.plan { StatusBadge(text: plan, color: .secondary) }
                    if active { StatusBadge(text: L10n.tr("Active")) }
                    if invalid {
                        StatusBadge(text: L10n.tr("Expired"), color: Color(nsColor: .systemOrange))
                            .hint(L10n.tr("The server voided this account's saved login, usually after changing accounts with /login or signing out in Claude. Sign in once more to fix it."))
                    }
                }
                HStack(spacing: 5) {
                    if account.email == nil {
                        Text(L10n.tr("No email address is stored locally for this account")).hint(L10n.tr("Claude Desktop only stores the account ID locally. The email becomes available after signing in to Claude Code or refreshing quota."))
                        Text("·")
                    }
                    Text(state.quotaUpdated(for: account.id, now: now)).hint(state.usageNotices[account.id])
                }.font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            if !invalid {
                Button { Task { await state.refreshNow(accountID: account.id) } } label: {
                    Group {
                        if state.usageRefreshingAccountID == account.id { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise").foregroundStyle(Palette.brand) }
                    }.frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(HoverRowStyle())
                .disabled(state.usageRefreshingAccountID != nil || state.authorizingQuotaAccess || state.working || state.demo)
                .accessibilityLabel(L10n.tr("Refresh quota"))
                .hint(L10n.tr("Refreshes this account's quota and reset times without switching accounts. Reads for one login are at least 60 seconds apart."))
            }
            if invalid {
                Button { state.showAddAccount = true } label: {
                    Label(L10n.tr("Sign in again"), systemImage: "person.crop.circle.badge.exclamationmark").labelStyle(.titleAndIcon)
                }
                .disabled(state.working)
                .hint(L10n.tr("Move the current login out of Claude, then sign in to this account in Claude; it will be saved"))
            } else if !active {
                Button { Task { await state.prepare(.switchAccount, target: account) } } label: {
                    Label(L10n.tr("Switch"), systemImage: "arrow.left.arrow.right").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.working)
                .hint(L10n.tr("Switch to this account"))
            }
            Menu { menuItems } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .frame(width: 26, height: 26).hoverSurface(radius: 7)
                .tint(.secondary).hint(L10n.tr("More actions"))
        }
    }
    @ViewBuilder private var menuItems: some View {
        Button(L10n.tr("View conversations for this account")) { state.selectedAccountID = account.id; state.page = .conversations }
        Divider()
        Button(L10n.tr("Remove from Claude Switch…"), role: .destructive) { removing = true }
            .disabled(!state.canRemove(account))
            .help(active ? L10n.tr("Switch to another account before removing the signed-in account") : "")
    }
}

private struct UsageErrorLine: View {
    @Environment(AppState.self) private var state
    let accountID: String
    var body: some View {
        SecondsTimeline(running: state.usageCooldowns[accountID] != nil) {
            if let error = state.usageStatus(for: accountID) {
                HStack(spacing: 4) {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange).hint(error)
                    if state.usageError(for: accountID) != nil { Button { state.dismissUsageError(accountID) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            .frame(width: 16, height: 16).contentShape(Rectangle())
                    }
                    .buttonStyle(HoverRowStyle()).foregroundStyle(.secondary).hint(L10n.tr("Dismiss")) }
                }.font(.system(size: 11))
            }
        }
    }
}
