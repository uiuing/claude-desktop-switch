import SwiftUI
import SwitchCore

struct OperationSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) var dismiss
    let operation: PendingOperation
    private var current: PendingOperation { state.pending ?? operation }
    private var source: Account? { current.plan.sourceAccountID.flatMap { id in state.knownAccounts.first { $0.id == id } } }
    private var title: String {
        switch current.plan.kind {
        case .capture: return L10n.tr("Save login for {0}", L10n.argument(state.identity(current.target)))
        case .switchAccount: return L10n.tr("Switch to {0}", L10n.argument(state.identity(current.target)))
        case .signOut: return L10n.tr("Add account")
        case .migrate: return L10n.tr("Conversations for {0}", L10n.argument(state.identity(current.target)))
        case .recover: return L10n.tr("Recover unfinished operation")
        }
    }
    private var symbol: String {
        switch current.plan.kind {
        case .capture: return "square.and.arrow.down"; case .switchAccount: return "arrow.left.arrow.right"
        case .signOut: return "person.crop.circle.badge.plus"
        case .migrate: return "arrow.right.square"
        case .recover: return "arrow.uturn.backward"
        }
    }
    private var confirmTitle: String {
        switch current.plan.kind {
        case .capture: return L10n.tr("Save"); case .switchAccount: return L10n.tr("Switch")
        case .signOut: return L10n.tr("Start")
        case .migrate: return L10n.tr("Continue")
        case .recover: return L10n.tr("Recover")
        }
    }
    /// Where the change comes from, shown as "origin → target" under the title.
    private var origin: String? {
        switch current.plan.kind {
        case .switchAccount: return source.map { state.identity($0) }
        case .migrate:
            let owners = Set(current.sessions.map(\.accountID))
            if owners.count == 1, let owner = owners.first { return state.identity(id: owner) }
            return L10n.tr("Accounts: {0}", L10n.argument(owners.count))
        case .capture, .signOut, .recover: return nil
        }
    }
    private var replacing: Bool { current.sessions.contains { state.replacesExisting($0, in: current) } }
    private var selectedTree: ConversationTree { ConversationTree(current.sessions) }
    private var listedSessions: [Conversation] { current.followCandidates ?? selectedTree.roots }
    private var rowHeight: CGFloat { current.followCandidates == nil ? 38 : 46 }
    private var visibleRows: Int { current.followCandidates == nil ? 5 : 4 }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if current.newAccountFollowUpID != nil {
                Text(L10n.tr("The new login is saved. These followed Code conversations have not been transferred yet."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !listedSessions.isEmpty { sessionsSection }
            stepsSection
            if !current.plan.warnings.isEmpty { warningsSection }
            if let error = current.selectionError {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(24).frame(width: 480)
        .interactiveDismissDisabled(state.working)
    }

    private var header: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(LinearGradient(colors: [Palette.brand.opacity(0.95), Palette.brand], startPoint: .top, endPoint: .bottom))
                .overlay(Image(systemName: symbol).font(.system(size: 19, weight: .semibold)).foregroundStyle(.white))
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 16, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                if let origin {
                    HStack(spacing: 6) {
                        Text(origin).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                        Text(state.identity(current.target)).lineLimit(1).truncationMode(.middle)
                    }.font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(current.plan.kind == .switchAccount
                     ? L10n.tr("Follow with this switch ({0})", L10n.argument(selectedTree.roots.count)) : L10n.tr("Conversations"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            Group {
                if listedSessions.count > visibleRows {
                    ScrollView { sessionRows }.frame(height: rowHeight * CGFloat(visibleRows))
                } else { sessionRows }
            }.card(radius: 10)
            VStack(alignment: .leading, spacing: 3) {
                if current.followCandidates != nil {
                    Text(L10n.tr("Code conversations active in the last 5 minutes are preselected. Choices are saved after switching."))
                }
                if listedSessions.contains(where: { state.conversationTree.childCount(of: $0) > 0 }) {
                    Text(L10n.tr("Subtasks follow their main conversation."))
                }
                if replacing { Text(L10n.tr("“Replaces” means the target account already has this conversation; it will be replaced with the current version.")) }
            }.font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sessionRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(listedSessions.enumerated()), id: \.element.id) { index, session in
                if index > 0 { Divider().padding(.leading, 42) }
                let selected = current.sessions.contains { $0.id == session.id }
                HStack(spacing: 10) {
                    if current.followCandidates != nil {
                        Toggle(session.title, isOn: Binding(get: { selected }, set: { selected in
                            Task { await state.setPendingFollow(selected, sessionID: session.id) }
                        })).toggleStyle(.checkbox).labelsHidden().disabled(state.working || current.preparingSelection)
                    } else { KindIcon(kind: session.kind, size: 20) }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(session.title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                            let count = selected && current.selectionReady ? selectedTree.childCount(of: session) : state.conversationTree.childCount(of: session)
                            if count > 0 { Text(L10n.tr("Subtasks: {0}", L10n.argument(count))).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize() }
                        }
                        if current.followCandidates != nil {
                            Text(Format.age(session.modifiedAt, now: Date())).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    if selected && current.selectionReady && state.replacesExisting(session, in: current) {
                        StatusBadge(text: L10n.tr("Replaces"), color: Color(nsColor: .systemOrange))
                    }
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 12).frame(height: rowHeight)
            }
        }
    }

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("What will happen")).font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(current.plan.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("\(index + 1)").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(Palette.brand)
                            .frame(width: 17, height: 17).background(Palette.brand.opacity(0.12), in: Circle())
                        Text(step).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).card(radius: 10)
        }
    }

    private var warningsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(current.plan.warnings, id: \.self) { warning in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange)
                    Text(warning).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.font(.system(size: 11))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !state.canExecute {
                Text(state.demo ? L10n.tr("Demo data; no changes will be made") : L10n.tr("Execution is disabled in this build"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if state.working || current.preparingSelection { ProgressView().controlSize(.small) }
            Button(L10n.tr("Cancel")) { state.pending = nil; dismiss() }.keyboardShortcut(.cancelAction).disabled(state.working)
            Button(confirmTitle) { Task { await state.executePending() } }
                .buttonStyle(.borderedProminent).prominentHover().keyboardShortcut(.defaultAction)
                .disabled(!state.canExecute || !current.selectionReady)
        }.padding(.top, 2)
    }
}

struct AddAccountSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 40)).foregroundStyle(Palette.brand)
                    .symbolRenderingMode(.hierarchical)
                Text(L10n.tr("Add account")).font(.system(size: 18, weight: .semibold))
                Text(L10n.tr("Your saved accounts stay here so you can switch back later."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 12) {
                if let account = state.activeAccount {
                    step(1, L10n.tr("Save {0} before adding another account", L10n.argument(state.identity(account))))
                    step(2, L10n.tr("Claude reopens on its sign-in screen"))
                    step(3, L10n.tr("Sign in to the account to add; Claude Switch saves it"))
                } else {
                    step(1, L10n.tr("Sign in to the account to add on Claude's sign-in screen"))
                    step(2, L10n.tr("Claude Switch saves it; switch with one click afterwards"))
                }
                Text(L10n.tr("After sign-in, confirm which conversations to bring to the new account."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).card(radius: 10)
            Group {
                if state.activeUnsaved {
                    LoginSaveStatus()
                } else if state.awaitingNewLogin {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10n.tr("Waiting for a new sign-in in Claude…"))
                    }
                } else {
                    Label(L10n.tr("Don't change accounts with /login or by signing out in Claude: that voids the saved login of the previous account."),
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                if let message = state.message {
                    Text(message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if state.working { ProgressView().controlSize(.small) }
                Button(L10n.tr("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(state.working)
                Button(state.activeAccount == nil ? L10n.tr("Open Claude") : L10n.tr("Start")) {
                    Task { await state.addAccount() }
                }
                .buttonStyle(.borderedProminent).prominentHover().keyboardShortcut(.defaultAction)
                .disabled(!state.canExecute || state.activeUnsaved)
            }
        }.padding(24).frame(width: 440)
        .interactiveDismissDisabled(state.working)
    }
    private func step(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text("\(number)").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(Palette.brand)
                .frame(width: 20, height: 20).background(Palette.brand.opacity(0.12), in: Circle())
            Text(text).font(.system(size: 13))
        }
    }
}
