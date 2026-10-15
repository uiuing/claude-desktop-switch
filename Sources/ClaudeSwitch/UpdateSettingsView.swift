import SwiftUI
import SwitchCore

struct UpdateSettingsView: View {
    @Bindable var updates: AppUpdates
    var body: some View {
        LabeledContent(L10n.tr("Current version"), value: updates.currentVersion)
        HStack(alignment: .top, spacing: 10) {
            if updates.isChecking { ProgressView().controlSize(.small) }
            else {
                Image(systemName: updates.hasUpdate ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath")
                    .foregroundStyle(updates.hasUpdate ? Palette.brand : .secondary)
            }
            Text(updates.statusText).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        HStack(spacing: 12) {
            Button(L10n.tr("Check for updates")) { Task { await updates.check(manual: true) } }
                .disabled(updates.isChecking)
            Link(L10n.tr("View latest version"), destination: ProjectLink.releases)
        }
        Toggle(L10n.tr("Check for updates automatically"), isOn: Binding(get: { updates.automatic }, set: updates.setAutomatic))
        Text(L10n.tr("Checks GitHub once a day while the app is open. New versions are downloaded and installed by you."))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
