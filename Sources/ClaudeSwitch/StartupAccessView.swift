import AppKit
import SwiftUI
import SwitchCore

struct StartupAccessView: View {
    @Environment(AppState.self) private var state
    var compact = false
    private var access: StartupAccess { state.startupAccess }
    var body: some View {
        Group {
            if compact { content.padding(20).frame(maxWidth: .infinity) }
            else {
                GeometryReader { bounds in
                    content.padding(32).frame(width: min(620, bounds.size.width))
                        .frame(width: bounds.size.width, height: bounds.size.height)
                }
            }
        }.tint(Palette.brand)
    }
    private var content: some View {
        VStack(spacing: compact ? 10 : 18) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: compact ? 28 : 52, height: compact ? 28 : 52)
            VStack(spacing: 8) {
                Text(access.isBusy ? L10n.tr("Checking access…") : L10n.tr("Allow access to continue"))
                    .font(compact ? .headline : .title2).fontWeight(.semibold)
                if !compact {
                    Text(L10n.tr("Set up access for account quota, saved logins and switch notifications."))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }.multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: compact ? 10 : 12) {
                permission(.quota, title: L10n.tr("Read account quota"), name: "Claude Safe Storage",
                           purpose: L10n.tr("Uses your Claude login to check account quota."))
                Divider()
                permission(.vault, title: L10n.tr("Protect saved logins"), name: L10n.tr("Claude Switch · Saved Logins"),
                           purpose: L10n.tr("Encrypts and opens saved logins and recovery copies for account switching."))
                if access.notificationChoiceNeeded {
                    Divider()
                    VStack(alignment: .leading, spacing: 5) {
                        Toggle(L10n.tr("Enable switch notifications"), isOn: Binding(
                            get: { access.wantsNotifications }, set: { access.wantsNotifications = $0 }))
                            .toggleStyle(.switch).font(.system(size: compact ? 12 : 13, weight: .semibold))
                            .disabled(access.isBusy)
                        Text(L10n.tr("Get switch completion and account recommendations. You can change this in Settings."))
                            .font(.system(size: compact ? 11 : 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.padding(compact ? 12 : 16).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("macOS may ask for each item separately. Choose Always Allow to remember access for this app build."))
                Text(L10n.tr("Enter your Mac login password only in the macOS dialog. Claude Switch does not receive it."))
                if !compact { Text(L10n.tr("Turning off notifications does not affect account switching or quota.")) }
            }.font(.system(size: compact ? 11 : 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            if access.authorizationFailed {
                Text(access.failureMessage ?? L10n.tr("Access is still unavailable. Check the macOS dialog and try again."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            if access.isBusy {
                ProgressView().controlSize(.small)
            } else {
                Button(access.confirmedItems.count == StartupAccess.Item.allCases.count ? L10n.tr("Continue") : L10n.tr("Allow access")) {
                    Task { await state.authorizeStartupAccess() }
                }
                    .buttonStyle(.borderedProminent).prominentHover().controlSize(.large)
            }
            Button { NSApplication.shared.terminate(nil) } label: {
                Text(L10n.tr("Quit")).padding(.horizontal, 8).padding(.vertical, 4)
                    .contentShape(Rectangle())
            }.buttonStyle(HoverRowStyle()).foregroundStyle(.secondary)
        }
    }
    private func permission(_ item: StartupAccess.Item, title: String, name: String, purpose: String) -> some View {
        let granted = access.confirmedItems.contains(item)
        return HStack(alignment: .top, spacing: 10) {
            if access.checkingItem == item { ProgressView().controlSize(.small).frame(width: 16) }
            else {
                Image(systemName: granted ? "checkmark.circle.fill" : "lock.circle")
                    .foregroundStyle(granted ? Color.green : .secondary).frame(width: 16)
                    .accessibilityLabel(granted ? L10n.tr("Access granted") : L10n.tr("Access needed"))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: compact ? 12 : 13, weight: .semibold))
                Text(purpose).font(.system(size: compact ? 11 : 12)).foregroundStyle(.secondary)
                Text(L10n.tr("Keychain item: {0}", L10n.argument(name)))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
