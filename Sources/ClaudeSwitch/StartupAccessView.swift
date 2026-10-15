import AppKit
import SwiftUI
import SwitchCore

struct StartupAccessView: View {
    @Environment(AppState.self) private var state
    var compact = false
    private var access: StartupAccess { state.startupAccess }
    var body: some View {
        Group {
            if compact { content.padding(24).frame(maxWidth: .infinity) }
            else {
                GeometryReader { bounds in
                    content.padding(40).frame(width: min(500, bounds.size.width))
                        .frame(width: bounds.size.width, height: bounds.size.height)
                }
            }
        }.tint(Palette.brand)
    }
    private var content: some View {
        VStack(spacing: compact ? 14 : 20) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: compact ? 40 : 64, height: compact ? 40 : 64)
            VStack(spacing: 8) {
                Text(access.isBusy ? L10n.tr("Checking access…") : L10n.tr("Allow access to continue"))
                    .font(compact ? .headline : .title2).fontWeight(.semibold)
                Text(L10n.tr("Claude Switch needs access to Claude Safe Storage in Keychain."))
                    .font(.system(size: compact ? 12 : 13)).foregroundStyle(.secondary)
                if access.authorizationFailed {
                    Text(L10n.tr("Access is still unavailable. Allow access in the macOS dialog, or sign in to Claude Desktop first."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if access.isBusy {
                ProgressView().controlSize(.small)
            } else {
                Button(L10n.tr("Allow access")) { Task { await state.authorizeStartupAccess() } }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
            Button(L10n.tr("Quit")) { NSApplication.shared.terminate(nil) }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }
}
