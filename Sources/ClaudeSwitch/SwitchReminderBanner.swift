import SwiftUI
import SwitchCore

struct SwitchReminderBanner: View {
    @Environment(AppState.self) private var state
    let reminder: SwitchReminder
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: reminder.kind == .expiring ? "arrow.left.arrow.right.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 20)).foregroundStyle(reminder.exhausted ? .red : Palette.brand)
            VStack(alignment: .leading, spacing: 6) {
                Text(reminder.title).font(.system(size: 13, weight: .semibold))
                Text(reminder.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button(L10n.tr("Review switch")) { Task { await state.reviewSwitchReminder(reminder.id) } }
                        .buttonStyle(.borderedProminent).prominentHover().disabled(state.working || state.reviewingReminder)
                    if !state.notifications.enabled, state.notifications.access == .notDetermined {
                        Button(L10n.tr("Enable notifications")) { Task { await state.enableNotifications() } }
                            .buttonStyle(.borderless).hoverSurface().disabled(state.notifications.requesting)
                    }
                }.controlSize(.small)
            }.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { state.dismissSwitchReminder() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }.buttonStyle(HoverRowStyle()).foregroundStyle(.secondary).hint(L10n.tr("Dismiss"))
        }
        .padding(16).frame(maxWidth: 520, alignment: .leading)
        .tint(Palette.brand)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.brand.opacity(0.3)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
