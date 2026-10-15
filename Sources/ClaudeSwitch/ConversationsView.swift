import SwiftUI
import SwitchCore

struct ConversationsView: View {
    @Environment(AppState.self) private var state
    private func groups(_ sessions: [Conversation]) -> [(account: String, sessions: [Conversation])] {
        var result: [(account: String, sessions: [Conversation])] = []
        for session in sessions {
            if result.last?.account == session.accountID { result[result.count - 1].sessions.append(session) }
            else { result.append((session.accountID, [session])) }
        }
        return result
    }
    var body: some View {
        let sessions = state.sessions
        Group {
            if sessions.isEmpty {
                if state.search.isEmpty {
                    ContentUnavailableView(L10n.tr("No conversations"), systemImage: "bubble.left.and.text.bubble.right",
                                           description: Text(L10n.tr("Conversations appear here after you use Code or Cowork in Claude Desktop.")))
                } else {
                    ContentUnavailableView.search(text: state.search)
                }
            } else {
                List(selection: Bindable(state).selectedSessionIDs) {
                    if state.library.preferences.sessionSort == .account {
                        ForEach(groups(sessions), id: \.account) { group in
                            Section(state.identity(id: group.account)) {
                                ForEach(group.sessions) { SessionRow(session: $0, showAccount: false).tag($0.id) }
                            }
                        }
                    } else {
                        ForEach(sessions) { SessionRow(session: $0, showAccount: true).tag($0.id) }
                    }
                }
                .listStyle(.inset)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { filterBar }
        .navigationTitle(L10n.tr("Conversations"))
        .navigationSubtitle(subtitle(total: sessions.count))
        .searchable(text: Bindable(state).search, placement: .toolbar, prompt: L10n.tr("Search conversations, projects or accounts"))
        .toolbar {
            InventoryToolbar(state: state)
            ToolbarItem(placement: .primaryAction) {
                Button { state.showSessionInspector.toggle() } label: { Label(L10n.tr("Details"), systemImage: "sidebar.right") }.help(L10n.tr("Show or hide details"))
            }
        }
        .onChange(of: state.library.preferences.sessionSort) { _, _ in state.persist() }
    }
    private var filterBar: some View {
        HStack(spacing: 10) {
            Picker(L10n.tr("Type"), selection: Bindable(state).sessionFilter) {
                Text(L10n.tr("All")).tag(SessionKind?.none)
                Text("Code").tag(SessionKind?.some(.code))
                Text("Cowork").tag(SessionKind?.some(.cowork))
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Spacer(minLength: 8)
            Menu {
                Picker(L10n.tr("Accounts"), selection: Bindable(state).selectedAccountID) {
                    Text(L10n.tr("All accounts")).tag(String?.none)
                    ForEach(sessionAccounts) { Text(state.identity($0)).tag(String?.some($0.id)) }
                }.pickerStyle(.inline)
                Picker(L10n.tr("Sort"), selection: Bindable(state).library.preferences.sessionSort) {
                    Text(L10n.tr("By time")).tag(SessionSort.time)
                    Text(L10n.tr("Group by account")).tag(SessionSort.account)
                }.pickerStyle(.inline)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: state.selectedAccountID == nil
                          ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    Text(state.selectedAccountID.map { state.identity(id: $0) } ?? L10n.tr("All accounts"))
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 170)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle())
                .font(.system(size: 12))
                .foregroundStyle(state.selectedAccountID == nil ? Color.secondary : Palette.brand)
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
            .hoverSurface()
            .help(L10n.tr("Filter and sort"))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(minWidth: 0, maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
    private var sessionAccounts: [Account] {
        let owners = Set(state.unarchivedSessions.map(\.accountID))
        return state.knownAccounts.filter { owners.contains($0.id) }
    }
    private func subtitle(total: Int) -> String {
        let following = state.followedSessionCount
        return following > 0 ? L10n.tr("Conversations: {0} · Following switches: {1}", L10n.argument(total), L10n.argument(following)) : L10n.tr("Conversations: {0}", L10n.argument(total))
    }
}

private struct SessionRow: View {
    @Environment(AppState.self) private var state
    var session: Conversation
    var showAccount: Bool
    var body: some View {
        HStack(spacing: 11) {
            KindIcon(kind: session.kind, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack(spacing: 4) {
                    if showAccount { Text(state.identity(id: session.accountID)).truncationMode(.middle); Text("·") }
                    if let project = session.project { Text(URL(fileURLWithPath: project).lastPathComponent); Text("·") }
                    Text(Format.age(session.modifiedAt, now: Date()))
                    if session.archived { Text(L10n.tr("· Archived")) }
                }.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if state.follows(session) {
                Image(systemName: "link").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.brand)
                    .help(L10n.tr("Follow account switches"))
            }
        }
        .padding(.vertical, 4)
        .listRowHover(radius: 8)
        .contextMenu {
            if session.kind == .code {
                let targets = state.accounts.filter { $0.id != session.accountID }
                ForEach(SessionTransferMode.allCases, id: \.self) { mode in
                    Menu(mode == .move ? L10n.tr("Move to") : L10n.tr("Copy to")) {
                        ForEach(targets) { account in
                            Button(state.identity(account)) {
                                state.setTransferMode(mode, sessions: [session])
                                Task { await state.prepare(.migrate, target: account, sessions: [session]) }
                            }
                        }
                    }.disabled(targets.isEmpty || state.working)
                }
                Divider()
                Button(state.follows(session) ? L10n.tr("Stop following switches") : L10n.tr("Follow account switches")) { state.toggleFollow(session) }
                    .disabled(session.cliSessionID == nil)
            }
        }
    }
}

struct SessionInspector: View {
    @Environment(AppState.self) private var state
    var body: some View {
        let selected = state.selectedSessions
        Group {
            if selected.count > 1 { multiple(selected) }
            else if let session = selected.first { single(session) }
            else {
                ContentUnavailableView(L10n.tr("No conversation selected"), systemImage: "sidebar.right",
                                       description: Text(L10n.tr("Select a conversation to see details. Hold ⌘ to select more than one.")))
            }
        }
    }
    private func single(_ session: Conversation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    KindIcon(kind: session.kind, size: 22)
                    Text(session.kind.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    if session.archived { StatusBadge(text: L10n.tr("Archived"), color: .secondary) }
                }
                Text(session.title).font(.system(size: 17, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                VStack(spacing: 0) {
                    info(L10n.tr("Account")) { Text(state.identity(id: session.accountID)) }
                    Divider()
                    info(L10n.tr("Last active")) { Text(Format.date(session.modifiedAt)) }
                    if let model = session.model { Divider(); info(L10n.tr("Model")) { Text(Format.model(model)) } }
                    if let project = session.project {
                        Divider()
                        info(L10n.tr("Project")) { Text(URL(fileURLWithPath: project).lastPathComponent).help(project) }
                    }
                }.card(radius: 10)
                if session.kind == .code {
                    transferCard([session])
                } else {
                    Label(L10n.tr("Cowork conversations cannot yet be copied to other accounts"), systemImage: "info.circle")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.padding(18)
        }
    }
    private func multiple(_ sessions: [Conversation]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("Selected conversations: {0}", L10n.argument(sessions.count))).font(.system(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(sessions.prefix(6)) { session in
                    HStack(spacing: 8) {
                        KindIcon(kind: session.kind, size: 18)
                        Text(session.title).font(.system(size: 12)).lineLimit(1)
                    }
                }
                if sessions.count > 6 { Text(L10n.tr("More: {0}", L10n.argument(sessions.count - 6))).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            if sessions.allSatisfy({ $0.kind == .code }) { transferCard(sessions) }
            Spacer()
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
    }
    /// The move/copy choice here is the same one the follow toggle and the confirmation sheet use.
    private func transferCard(_ sessions: [Conversation]) -> some View {
        let mode = state.transferMode(sessions)
        let single = sessions.count == 1 ? sessions.first : nil
        return VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("Transfer to another account")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            SessionTransferModePicker(selection: Binding(get: { mode },
                                                         set: { if let new = $0 { state.setTransferMode(new, sessions: sessions) } }))
                .controlSize(.regular).fixedSize()
            Text(mode?.explanation ?? L10n.tr("The selected conversations use different choices. Pick one to apply to all."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let session = single {
                Divider().padding(.vertical, 2)
                Toggle(isOn: Binding(get: { state.follows(session) }, set: { _ in state.toggleFollow(session) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.tr("Follow account switches")).font(.system(size: 13, weight: .medium))
                        Text(followCaption(session)).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.toggleStyle(.switch).controlSize(.small).disabled(session.cliSessionID == nil)
            }
            transferMenu(sessions, mode: mode).padding(.top, 2)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).card(radius: 10)
    }
    private func followCaption(_ session: Conversation) -> String {
        guard session.cliSessionID != nil else { return L10n.tr("This conversation's local history is missing, so it cannot be transferred.") }
        return state.transferMode(session) == .move
            ? L10n.tr("When you switch accounts, it moves along and replaces the older version in the target account.")
            : L10n.tr("When you switch accounts, it is copied along and replaces the older version in the target account.")
    }
    private func transferMenu(_ sessions: [Conversation], mode: SessionTransferMode?) -> some View {
        let targets = transferTargets(sessions)
        let title = mode == .move ? L10n.tr("Move to…") : mode == .copy ? L10n.tr("Copy to…") : L10n.tr("Transfer to…")
        return Menu {
            ForEach(targets) { account in
                Button(state.identity(account)) { Task { await state.prepare(.migrate, target: account, sessions: sessions) } }
            }
        } label: {
            Label(title, systemImage: mode == .copy ? "plus.square.on.square" : "arrow.right.square").frame(maxWidth: .infinity)
        }
        .menuStyle(.button).buttonStyle(.bordered).controlSize(.large).fixedSize()
        .disabled(targets.isEmpty || state.working)
    }
    private func transferTargets(_ sessions: [Conversation]) -> [Account] {
        let sources = Set(sessions.map(\.accountID))
        return state.accounts.filter { !sources.contains($0.id) || sources.count > 1 }
    }
    private func info<Value: View>(_ title: String, @ViewBuilder value: () -> Value) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            value().lineLimit(1).truncationMode(.middle)
        }.font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 9)
    }
}
