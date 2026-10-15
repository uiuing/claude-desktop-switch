import AppKit
import SwiftUI
import SwitchCore

struct MainWindow: View {
    @Environment(AppState.self) private var state
    var body: some View {
        Group {
            if state.startupAccess.isReady { AuthorizedWorkbench() }
            else { StartupAccessView() }
        }.background(WorkbenchWindowObserver())
    }
}

private struct AuthorizedWorkbench: View {
    @Environment(AppState.self) private var state
    var body: some View {
        NavigationSplitView {
            Sidebar().navigationSplitViewColumnWidth(min: 210, ideal: 228, max: 280)
        } detail: {
            VStack(spacing: 0) {
                if !state.recoveryIDs.isEmpty && state.page != .settings { RecoveryBanner() }
                switch state.page {
                case .accounts: AccountsView()
                case .conversations: ConversationsView()
                case .usage: AnalyticsView()
                case .settings: SettingsView()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // On the split view itself, not inside the detail: a nested inspector split
        // lags behind sidebar animations and overflows the window mid-transition.
        .inspector(isPresented: sessionInspector) {
            SessionInspector().inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        // The minimum size lives on the NSWindow (see WorkbenchWindowObserver). A SwiftUI
        // min frame here stops the detail from shrinking while the sidebar expands.
        .tint(Palette.brand)
        .sheet(item: Bindable(state).pending) { OperationSheet(operation: $0).environment(state) }
        .sheet(isPresented: Bindable(state).showAddAccount) { AddAccountSheet().environment(state) }
        .sheet(isPresented: Bindable(state).showQuickFind) { QuickFind().environment(state) }
        .overlay(alignment: .bottom) {
            ZStack {
                if let message = state.message { Toast(message: message) { state.message = nil }.padding(.bottom, 24) }
            }.animation(.snappy(duration: 0.25), value: state.message)
        }
    }
    private var sessionInspector: Binding<Bool> {
        Binding(get: { state.page == .conversations && state.showSessionInspector },
                set: { if state.page == .conversations { state.showSessionInspector = $0 } })
    }
}

private struct Sidebar: View {
    @Environment(AppState.self) private var state
    private var selection: Binding<NavigationPage?> {
        Binding(get: { state.page == .settings ? nil : state.page }, set: { if let page = $0 { state.page = page } })
    }
    var body: some View {
        List(selection: selection) {
            Section {
                ForEach(NavigationPage.primary) { page in
                    Label(page.title, systemImage: page.symbol).badge(badge(page)).tag(page)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 9) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 24, height: 24)
                Text("Claude Switch").font(.system(size: 14, weight: .semibold))
                Spacer()
            }.padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 6) {
                if let account = state.activeAccount { CurrentAccountTile(account: account) }
                Button { state.page = .settings } label: {
                    Label(L10n.tr("Settings"), systemImage: "gearshape").font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(state.page == .settings ? Color.primary.opacity(0.09) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                }.buttonStyle(HoverRowStyle())
                Button { ProjectLink.open() } label: {
                    HStack(spacing: 6) {
                        Label("GitHub", systemImage: ProjectLink.symbol).font(.system(size: 13))
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
                }
                .buttonStyle(HoverRowStyle())
                .hint(L10n.tr("Open the project page on GitHub"))
            }.padding(.horizontal, 10).padding(.bottom, 10)
        }
    }
    private func badge(_ page: NavigationPage) -> Int {
        switch page {
        case .accounts: return state.accounts.count
        case .conversations: return state.unarchivedSessions.count
        default: return 0
        }
    }
}

private struct CurrentAccountTile: View {
    @Environment(AppState.self) private var state
    let account: Account
    var body: some View {
        Button { state.page = .accounts } label: {
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.identity(account)).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(state.quotaRows(for: account.id).map { "\($0.shortTitle) \($0.percentageText)" }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                Spacer(minLength: 0)
                Circle().fill(Palette.green).frame(width: 7, height: 7).help(L10n.tr("Signed in"))
            }
            .padding(9).card(radius: 10).contentShape(Rectangle())
        }.buttonStyle(CardButtonStyle(radius: 10))
    }
}

private struct RecoveryBanner: View {
    @Environment(AppState.self) private var state
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(L10n.tr("The previous operation did not finish and needs recovery.")).font(.system(size: 12, weight: .medium))
            Spacer()
            Button(L10n.tr("View")) { state.page = .settings }.controlSize(.small)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Color.orange.opacity(0.1))
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}

private struct Toast: View {
    let message: String
    let close: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(Palette.brand)
            Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(HoverRowStyle()).foregroundStyle(.secondary).hint(L10n.tr("Dismiss"))
        }
        .padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: 520)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.line))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Toolbar actions shared by pages that show live inventory.
struct InventoryToolbar: ToolbarContent {
    let state: AppState
    @State private var showWarnings = false
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let warnings = state.inventory?.warnings, !warnings.isEmpty {
                Button { showWarnings = true } label: { Label(L10n.tr("Notices"), systemImage: "exclamationmark.triangle") }
                    .help(L10n.tr("Read notices: {0}", L10n.argument(warnings.count)))
                    .popover(isPresented: $showWarnings) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(Set(warnings)).sorted(), id: \.self) { Text($0).font(.system(size: 12)) }
                        }.padding(16).frame(width: 300, alignment: .leading)
                    }
            }
            Button { Task { await state.refreshLocalRecords() } } label: {
                Label(L10n.tr("Refresh"), systemImage: "arrow.clockwise")
            }.disabled(state.refreshing)
                .help(L10n.tr("Refresh accounts and conversations"))
        }
    }
}

struct QuickFind: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) var dismiss
    @State private var query = ""
    private var accounts: [Account] {
        state.accounts.filter { query.isEmpty || ($0.email ?? "").localizedStandardContains(query) || $0.id.localizedStandardContains(query) }
    }
    private var sessions: [Conversation] {
        Array(state.unarchivedSessions
            .filter { query.isEmpty || $0.title.localizedStandardContains(query) }
            .sorted { $0.modifiedAt > $1.modifiedAt }.prefix(12))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(.secondary)
                TextField(L10n.tr("Search accounts or conversations"), text: $query).textFieldStyle(.plain).font(.system(size: 17))
                    .onSubmit { if let first = accounts.first { open(first) } else if let first = sessions.first { open(first) } }
            }.padding(.horizontal, 18).padding(.vertical, 15)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !accounts.isEmpty {
                        heading(L10n.tr("Accounts"))
                        ForEach(accounts) { account in
                            row { open(account) } label: {
                                Text(state.identity(account)).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                if account.id == state.activeID { StatusBadge(text: L10n.tr("Active")) }
                                Spacer()
                                Text(state.quotaRows(for: account.id).map { "\($0.shortTitle) \($0.percentageText)" }.joined(separator: "  "))
                                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                    if !sessions.isEmpty {
                        heading(L10n.tr("Conversations"))
                        ForEach(sessions) { session in
                            row { open(session) } label: {
                                KindIcon(kind: session.kind, size: 24)
                                Text(session.title).font(.system(size: 13)).lineLimit(1)
                                Spacer()
                                Text(Format.age(session.modifiedAt, now: Date())).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if accounts.isEmpty && sessions.isEmpty {
                        Text(L10n.tr("No results for “{0}”", L10n.argument(query))).font(.system(size: 13)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                }.padding(8)
            }.frame(height: 360)
        }.frame(width: 560)
    }
    private func heading(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
    }
    private func row<Label: View>(action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            HStack(spacing: 10, content: label).padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
        }.buttonStyle(HoverRowStyle())
    }
    private func open(_ account: Account) {
        state.page = .accounts; dismiss()
        guard account.id != state.activeID else { return }
        Task { await state.prepare(.switchAccount, target: account) }
    }
    private func open(_ session: Conversation) {
        state.page = .conversations; state.search = ""; state.selectedAccountID = nil; state.sessionFilter = nil
        state.selectedSessionIDs = [session.id]; dismiss()
    }
}

/// Rounded hover highlight shared by menu-like rows.
struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HoverRow(configuration: configuration) }
    private struct HoverRow: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering && enabled ? 0.07 : 0)))
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}
