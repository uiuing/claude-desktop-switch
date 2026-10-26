import AppKit
import SwiftUI
import SwitchCore
import SwitchStorage

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @AppStorage(L10n.preferenceKey) private var language = AppLanguage.system.rawValue
    @AppStorage(AppTheme.preferenceKey) private var theme = AppTheme.system.rawValue
    @AppStorage(Format.showResetTimeKey) private var showResetTime = true
    @State private var recovery: String?
    @AppStorage(WorkbenchLifecycle.showInMenuBarKey) private var showInMenuBar = true
    var body: some View {
        Form {
            Section(L10n.tr("Updates")) {
                UpdateSettingsView(updates: state.updates)
            }
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
            Section(L10n.tr("Notifications")) {
                Toggle(L10n.tr("macOS notifications"), isOn: Binding(get: { state.notifications.enabled }, set: { enabled in
                    Task {
                        if enabled { await state.enableNotifications() }
                        else { await state.notifications.setEnabled(false) }
                    }
                })).disabled(state.notifications.requesting || state.demo || state.notifications.access == .unavailable)
                Toggle(L10n.tr("Operation results"), isOn: Bindable(state.notifications).completions)
                    .disabled(!state.notifications.enabled)
                Toggle(L10n.tr("Switch recommendations"), isOn: Binding(get: { state.notifications.recommendations }, set: { enabled in
                    state.notifications.recommendations = enabled
                    state.updateSwitchReminder(notify: false)
                    if enabled, let reminder = state.switchReminder, reminder.needsReview {
                        Task { await state.notifications.showRecommendation(reminder) }
                    }
                }))
                    .disabled(!state.notifications.enabled)
                Text(L10n.tr("Remind once when quota is low, and again if it runs out. Click a notification or the marked menu bar icon to review a switch. Switching always requires confirmation."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(L10n.tr("Menu bar and in-app reminders remain available without notification permission."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if state.notifications.access == .denied {
                    Text(L10n.tr("Notifications are blocked in macOS Settings.")).font(.caption).foregroundStyle(.secondary)
                    Button(L10n.tr("Open Notification Settings")) { state.notifications.openSettings() }
                }
                if state.notifications.failed {
                    Text(L10n.tr("Could not enable or deliver notifications. Menu bar reminders are still available."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L10n.tr("Menu bar")) {
                Toggle(L10n.tr("Show in menu bar"), isOn: $showInMenuBar)
                Toggle(L10n.tr("Show GitHub, feedback and version links"), isOn: preference(\.showMenuProjectLinks))
                Toggle(L10n.tr("Show Claude Code task status"), isOn: Binding(
                    get: { state.library.preferences.showCodeTasks }, set: { state.setCodeTasksEnabled($0) }))
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
                Link(L10n.tr("Report an issue"), destination: ProjectLink.issues)
                Button(L10n.tr("Export diagnostics…")) { Task { await state.exportDiagnostics() } }
                    .disabled(state.demo || state.exportingDiagnostics || state.working)
                LabeledContent(L10n.tr("Runtime logs")) {
                    Button(L10n.tr("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([RuntimeLog.directory]) }
                        .disabled(state.demo)
                }
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
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.tr("Settings"))
        .task { await state.notifications.refreshAccess() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await state.notifications.refreshAccess() }
        }
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
