import AppKit
import SwiftUI
import SwitchCore

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @AppStorage(L10n.preferenceKey) private var language = AppLanguage.system.rawValue
    @AppStorage(AppTheme.preferenceKey) private var theme = AppTheme.system.rawValue
    @AppStorage(Format.showResetTimeKey) private var showResetTime = true
    @State private var recovery: String?
    @AppStorage(WorkbenchLifecycle.showInMenuBarKey) private var showInMenuBar = true
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    var body: some View {
        Form {
            Section(L10n.tr("Appearance")) {
                Picker(L10n.tr("Theme"), selection: $theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text(L10n.tr("Theme changes apply immediately to the main window and menu bar panel."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(L10n.tr("Language")) {
                Picker(L10n.tr("Display language"), selection: $language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.nativeName)
                            .tag(language.rawValue)
                    }
                }
                Text(L10n.tr("Language changes apply immediately. System follows the preferred languages in macOS."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(L10n.tr("Reset time")) {
                Toggle(L10n.tr("Show reset date and time"), isOn: $showResetTime)
                Text(L10n.tr("Turn off to show time remaining until reset. Applies to the account list and menu bar."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(L10n.tr("Quota refresh")) {
                Toggle(L10n.tr("Refresh quota automatically"), isOn: quotaPreference(\.enabled))
                Group {
                    intervalPicker(L10n.tr("Current account interval"), key: \.baselineMinutes, choices: [5, 10, 15, 30, 60])
                    intervalPicker(L10n.tr("Other accounts interval"), key: \.otherAccountsMinutes, choices: [15, 30, 60, 120])
                    Toggle(L10n.tr("Adjust to conversation activity"), isOn: quotaPreference(\.adaptive))
                    Group {
                        intervalPicker(L10n.tr("Minimum interval"), key: \.minimumMinutes, choices: [1, 2, 5])
                        intervalPicker(L10n.tr("Quiet interval"), key: \.quietMinutes,
                                       choices: [15, 30, 60, 120].filter { $0 >= state.library.preferences.quotaRefresh.baselineMinutes })
                    }.disabled(!state.library.preferences.quotaRefresh.adaptive)
                }.disabled(!state.library.preferences.quotaRefresh.enabled)
                Text(L10n.tr("More frequent conversation changes refresh the current account faster. After 30 minutes without changes, the quiet interval applies. Other accounts use their own interval."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(L10n.tr("Automatic refresh pauses when Claude quits. Accounts refresh one at a time; server cooldowns always apply."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(L10n.tr("Menu bar")) {
                Toggle(L10n.tr("Show in menu bar"), isOn: $showInMenuBar)
                Toggle(L10n.tr("Mask email addresses (keep first and last characters)"), isOn: preference(\.maskEmail))
            }
            if !state.recoveryIDs.isEmpty {
                Section(L10n.tr("Unfinished operations")) {
                    ForEach(state.recoveryIDs, id: \.self) { id in
                        LabeledContent(L10n.tr("Operation {0}", L10n.argument(id.prefix(8)))) {
                            Button(L10n.tr("Recover…")) { recovery = id }.disabled(!state.canExecute)
                        }
                    }
                }
            }
            Section(L10n.tr("About")) {
                LabeledContent(L10n.tr("Version"), value: version)
                LabeledContent(L10n.tr("Source code")) {
                    Link(destination: ProjectLink.repository) {
                        HStack(spacing: 4) {
                            Label("GitHub", systemImage: ProjectLink.symbol)
                            Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                        }
                    }
                }
                LabeledContent(L10n.tr("Data")) {
                    Button(L10n.tr("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([state.environment.root]) }
                }
                Text(L10n.tr("Claude Switch doesn't have remote or automatic updates yet. Follow the project on GitHub for new releases."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.tr("Settings"))
        .alert(L10n.tr("Recover this unfinished operation?"), isPresented: Binding(get: { recovery != nil }, set: { if !$0 { recovery = nil } })) {
            Button(L10n.tr("Cancel"), role: .cancel) { recovery = nil }
            Button(L10n.tr("Recover")) { if let id = recovery { Task { await state.recover(id) } }; recovery = nil }
        } message: { Text(L10n.tr("Quit Claude first. Files will return to their previous state; content written since then will be saved separately.")) }
    }
    private func preference(_ key: WritableKeyPath<Preferences, Bool>) -> Binding<Bool> {
        Binding(get: { state.library.preferences[keyPath: key] },
                set: { state.library.preferences[keyPath: key] = $0; state.persist() })
    }
    private func quotaPreference<Value>(_ key: WritableKeyPath<QuotaRefreshPreferences, Value>) -> Binding<Value> {
        Binding(get: { state.library.preferences.quotaRefresh[keyPath: key] }, set: { value in
            var preferences = state.library.preferences.quotaRefresh
            preferences[keyPath: key] = value
            state.setQuotaRefreshPreferences(preferences)
        })
    }
    private func intervalPicker(_ title: String, key: WritableKeyPath<QuotaRefreshPreferences, Int>, choices: [Int]) -> some View {
        Picker(title, selection: quotaPreference(key)) {
            ForEach(choices, id: \.self) { minutes in
                Text(L10n.tr("{0} min", minutes.formatted(.number.locale(L10n.locale)))).tag(minutes)
            }
        }
    }
}
