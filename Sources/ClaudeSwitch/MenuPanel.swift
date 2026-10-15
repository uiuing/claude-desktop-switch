import AppKit
import SwiftUI
import SwitchCore

struct MenuPanel: View {
    var automaticallyReviewReminders = true
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @State private var menuSnapshot: AccountMenuSnapshot?
    var body: some View {
        Group {
            if state.startupAccess.isReady { authorizedContent }
            else { StartupAccessView(compact: true).frame(width: 330).background(MenuPanelWindowReader()) }
        }
    }
    private var authorizedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            separator
            if let reminder = state.switchReminder {
                Button {
                    show(.accounts)
                    Task { await state.reviewSwitchReminder(reminder.id) }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: reminder.kind == .expiring ? "arrow.left.arrow.right.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(Palette.brand)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(reminder.title).font(.system(size: 12, weight: .semibold))
                            Text(reminder.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(L10n.tr("Review switch")).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.brand)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.brand.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(CardButtonStyle(radius: 9)).disabled(state.working || state.reviewingReminder)
                    .padding(.horizontal, 10)
                separator
            }
            if state.showsNewAccountFollowUp {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("Login saved · Conversations not transferred")).font(.system(size: 12, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L10n.tr("View")) { show(.accounts) }.controlSize(.small)
                }.padding(.horizontal, 14).padding(.vertical, 8)
                separator
            }
            if state.quotaAccessRequired || state.authorizingQuotaAccess {
                QuotaAccessStatus().padding(.horizontal, 14).padding(.vertical, 6)
                separator
            } else if let reason = state.quotaRefreshPause {
                QuotaRefreshPauseStatus(reason: reason, compact: true).padding(.horizontal, 14).padding(.vertical, 8)
                separator
            }
            if state.activeUnsaved { LoginSaveStatus(compact: true).padding(.horizontal, 14).padding(.vertical, 6) }
            if state.accounts.isEmpty {
                if !state.activeUnsaved {
                    VStack(spacing: 6) {
                        Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 26)).foregroundStyle(.secondary)
                        Text(L10n.tr("No accounts yet")).font(.system(size: 13, weight: .medium))
                        Text(L10n.tr("Saved automatically after signing in to Claude Desktop")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 22)
                }
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let ranking = state.accountRanking(now: context.date)
                    let suggestion = menuSnapshot == nil ? ranking.advice : menuSnapshot?.advice(from: ranking)
                    let ordered = (menuSnapshot?.accounts(from: ranking) ?? ranking.displayAccounts).filter { $0.id != state.activeID }
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Text(L10n.tr("Accounts"))
                            Spacer()
                            ForEach(["five_hour", "seven_day"], id: \.self) { id in
                                Text(L10n.quotaShortTitle(id) ?? id).lineLimit(1).minimumScaleFactor(0.75)
                                    .frame(width: MenuQuotaColumn.width, alignment: .trailing)
                            }
                        }
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 14).padding(.bottom, 4)
                        ScrollView {
                            VStack(spacing: 0) {
                                if let active = state.activeAccount {
                                    Divider().padding(.horizontal, 14)
                                    MenuAccountRow(account: active, now: context.date, active: true, advice: suggestion)
                                }
                                ForEach(ordered) { account in
                                    Divider().padding(.horizontal, 14)
                                    MenuAccountRow(account: account, now: context.date,
                                                   advice: account.id == suggestion?.accountID ? suggestion : nil) {
                                        show(.accounts)
                                        Task { await state.prepare(.switchAccount, target: account) }
                                    }
                                }
                            }
                        }.frame(maxHeight: 460).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let message = state.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.top, 4).fixedSize(horizontal: false, vertical: true)
            }
            separator
            VStack(spacing: 0) {
                MenuAction(title: L10n.tr("Add account…"), symbol: "plus.circle") { show(.accounts); state.showAddAccount = true }
                MenuAction(title: L10n.tr("Conversations"), symbol: NavigationPage.conversations.symbol) { show(.conversations) }
                MenuAction(title: L10n.tr("Usage statistics"), symbol: NavigationPage.usage.symbol) { show(.usage) }
            }.padding(.horizontal, 6)
            separator
            VStack(spacing: 0) {
                MenuAction(title: L10n.tr("Open Claude Switch"), symbol: "macwindow") { show(state.page == .settings ? .accounts : state.page) }
                MenuAction(title: "GitHub", symbol: ProjectLink.symbol, external: true) {
                    MenuPanelWindowReader.panel?.close(); ProjectLink.open()
                }.hint(L10n.tr("Open the project page on GitHub"))
                MenuAction(title: L10n.tr("Report an issue"), symbol: "bubble.left", external: true) {
                    MenuPanelWindowReader.panel?.close(); NSWorkspace.shared.open(ProjectLink.issues)
                }
                MenuAction(title: state.updates.hasUpdate ? L10n.tr("Update available") : L10n.tr("View latest version"),
                           symbol: "arrow.down.circle", external: true) {
                    MenuPanelWindowReader.panel?.close(); NSWorkspace.shared.open(ProjectLink.releases)
                }
                MenuAction(title: L10n.tr("Settings…"), symbol: "gearshape", detail: "⌘,") { show(.settings) }
                MenuAction(title: L10n.tr("Quit"), symbol: "power", detail: "⌘Q") { NSApplication.shared.terminate(nil) }
            }.padding(.horizontal, 6)
        }
        .padding(.bottom, 6)
        .frame(width: 330)
        .tint(Palette.brand)
        .background(MenuPanelWindowReader(onVisibilityChange: { visible in
            menuSnapshot = visible ? AccountMenuSnapshot(state.accountRanking()) : nil
            if visible { reviewUnseenReminder() }
        }))
        .onAppear { menuSnapshot = AccountMenuSnapshot(state.accountRanking()) }
        .onDisappear { menuSnapshot = nil }
    }
    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 20, height: 20)
            Text("Claude Switch").font(.headline)
            Spacer()
            let busy = state.refreshing
            Button { Task { await state.refreshLocalRecords() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                    .rotationEffect(.degrees(busy ? 360 : 0))
                    .animation(busy ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: busy)
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }.buttonStyle(HoverRowStyle()).disabled(busy)
                .hint(L10n.tr("Refresh accounts and conversations"))
        }.padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 2)
    }
    private var separator: some View { Divider().padding(.horizontal, 14).padding(.vertical, 6) }
    private func reviewUnseenReminder() {
        // The marked status item is a direct review shortcut once per reminder. Later clicks open the normal menu.
        guard automaticallyReviewReminders, MenuPanelWindowReader.panel?.isVisible == true,
              let reminder = state.switchReminder, reminder.needsReview,
              !state.working, !state.reviewingReminder, state.pending == nil,
              !state.showAddAccount, !state.showQuickFind else { return }
        show(.accounts)
        Task { await state.reviewSwitchReminder(reminder.id) }
    }
    private func show(_ page: NavigationPage) {
        // The status-item panel floats above every window; it would cover the sheet opened next.
        MenuPanelWindowReader.panel?.close()
        WorkbenchLifecycle.shared.prepareToOpen()
        state.page = page; openWindow(id: "library"); NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

/// The MenuBarExtra panel has no dismiss API; keep its window so actions can close it.
private struct MenuPanelWindowReader: NSViewRepresentable {
    @MainActor static weak var panel: NSWindow?
    var onVisibilityChange: ((Bool) -> Void)?
    final class Attachment: NSView {
        var onVisibilityChange: ((Bool) -> Void)?
        private var visibility: NSKeyValueObservation?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            visibility = nil
            if let window {
                MenuPanelWindowReader.panel = window
                visibility = window.observe(\.isVisible, options: [.initial, .new]) { [weak self] window, _ in
                    let visible = window.isVisible
                    DispatchQueue.main.async { [weak self] in self?.onVisibilityChange?(visible) }
                }
            }
        }
    }
    func makeNSView(context: Context) -> Attachment {
        let view = Attachment(); view.onVisibilityChange = onVisibilityChange; return view
    }
    func updateNSView(_ view: Attachment, context: Context) { view.onVisibilityChange = onVisibilityChange }
}

/// One table row per saved account: status dot, identity over a status line, then a column per quota window.
/// Other accounts switch on click; the suggested one is listed first and tinted. Each status line describes
/// its own account: a shortage on the signed-in row, unspent quota about to reset on the suggested row.
/// Full reset dates and the reasons in full live in the tooltip.
private struct MenuAccountRow: View {
    @AppStorage(Format.showResetTimeKey) private var showResetTime = true
    @Environment(AppState.self) private var state
    let account: Account
    let now: Date
    var active = false
    var advice: SwitchAdvice?
    var action: (() -> Void)?
    private var suggested: Bool { !active && advice != nil }
    var body: some View {
        if let action {
            Button(action: action) { content }.buttonStyle(MenuTableRowStyle(tint: suggested ? Palette.brand : nil)).hint(hint)
        } else {
            content.hint(hint)
        }
    }
    private var content: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle().fill(active ? Palette.green : suggested ? Palette.brand : Color.primary.opacity(0.15)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.identity(account)).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                SecondsTimeline(running: state.usageCooldowns[account.id] != nil) {
                    Text(subtitle.text).font(.system(size: 11)).foregroundStyle(subtitle.color).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 6)
            ForEach(state.quotaRows(for: account.id, now: now)) { MenuQuotaColumn(row: $0, now: now) }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    private var shortage: (status: String, message: String)? {
        guard active, let advice else { return nil }
        switch advice.reason {
        case .fiveHourLow:
            return (L10n.tr("Active · session limit low"),
                    L10n.tr("Session limit almost used up; switch to the suggested account below"))
        case .sevenDayLow:
            return (L10n.tr("Active · weekly limit low"),
                    L10n.tr("Weekly limit almost used up; switch to the suggested account below"))
        case .expiring: return nil
        }
    }
    private var expiring: QuotaReadout? {
        guard suggested, case .expiring(let row) = advice?.reason else { return nil }
        return row
    }
    private var subtitle: (text: String, color: Color) {
        if let error = state.usageError(for: account.id) { return (error, .orange) }
        if state.usageRefreshingAccountID == account.id { return (L10n.tr("Reading quota…"), .secondary) }
        if state.usageNotices[account.id] != nil { return (L10n.tr("Check in Claude"), .orange) }
        if active {
            if let shortage { return (shortage.status, Color(nsColor: .systemOrange)) }
            return (account.planTitle + " · " + L10n.tr("Active"), Palette.green)
        }
        if account.loginInvalidAt != nil { return (L10n.tr("Expired · click to sign in again"), Color(nsColor: .systemOrange)) }
        if let expiring {
            let status = expiring.id == "five_hour" ? L10n.tr("Suggested · session limit resets soon")
                : L10n.tr("Suggested · weekly limit resets soon")
            return (status, Palette.brand)
        }
        if suggested { return (L10n.tr("Switch here"), Palette.brand) }
        if account.plan == nil { return (account.planTitle, .secondary) }
        return (account.planTitle + " · " + L10n.tr("Click to switch"), .secondary)
    }
    private var hint: String {
        var lines: [String] = []
        if let shortage { lines.append(shortage.message) }
        if let expiring {
            let reset = Format.compactReset(expiring, now: now, showResetTime: showResetTime)
            lines.append(expiring.id == "five_hour"
                ? L10n.tr("Session limit: {0}, {1} still unused", reset, expiring.percentageText)
                : L10n.tr("Weekly limit: {0}, {1} still unused", reset, expiring.percentageText))
        }
        if !active { lines.append(L10n.tr("Switch to {0}", L10n.argument(state.identity(account)))) }
        if let error = state.usageError(for: account.id) { lines.append(error) }
        for row in state.quotaRows(for: account.id, now: now) + state.extraQuotaRows(for: account.id, now: now) {
            lines.append([row.title + " " + row.percentageText, Format.resetDetail(row)].compactMap { $0 }.joined(separator: " · "))
        }
        lines.append(state.quotaUpdated(for: account.id, now: now))
        if active, let notice = state.usageNotices[account.id] { lines.append(notice) }
        return lines.joined(separator: "\n")
    }
}

/// Full-width table row that highlights on hover and press, over the suggested row's tint.
private struct MenuTableRowStyle: ButtonStyle {
    var tint: Color?
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration, tint: tint) }
    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color?
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.colorSchemeContrast) private var contrast
        var body: some View {
            let emphasis = enabled ? (configuration.isPressed ? 0.12 : hovering ? 0.08 : 0) : 0
            configuration.label
                .background((tint ?? .primary).opacity((tint == nil ? 0 : 0.07) + emphasis * (contrast == .increased ? 2 : 1)))
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovering = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering && enabled)
        }
    }
}

/// One quota window as a table column: what is left, a short bar, then when it resets.
private struct MenuQuotaColumn: View {
    static let width: CGFloat = 56
    @AppStorage(Format.showResetTimeKey) private var showResetTime = true
    let row: QuotaReadout
    let now: Date
    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(row.percentageText).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .foregroundStyle(row.remainingPercent.map { $0 <= 10 ? Palette.quota($0) : .primary } ?? .secondary)
            QuotaBar(row: row, height: 3).frame(width: 46)
            Text(Format.tinyReset(row, now: now, showResetTime: showResetTime))
                .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        }
        .frame(width: Self.width, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Format.quotaAccessibility(row, now: now, showResetTime: showResetTime))
    }
}

/// A menu-style row; `detail` is right-aligned secondary text such as a shortcut, `external` marks a web link.
private struct MenuAction: View {
    let title: String
    let symbol: String
    var detail: String?
    var external = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 16).foregroundStyle(.secondary)
                Text(title).font(.body)
                Spacer()
                if let detail { Text(detail).font(.body).foregroundStyle(.tertiary) }
                if external { Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary) }
            }.padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(HoverRowStyle())
    }
}
