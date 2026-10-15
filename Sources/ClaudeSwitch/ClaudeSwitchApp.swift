import AppKit
import SwiftUI
import SwitchCore

@main
struct ClaudeSwitchApp: App {
    @NSApplicationDelegateAdaptor(SwitchAppDelegate.self) private var delegate
    @AppStorage(L10n.preferenceKey) private var language = AppLanguage.system.rawValue
    @State private var localeRevision = 0
    @State private var state = AppState.shared
    @AppStorage(WorkbenchLifecycle.showInMenuBarKey) private var showInMenuBar = true
    var body: some Scene {
        // Keep the workbench first for macOS 14's default scene selection.
        Window("Claude Switch", id: "library") {
            MainWindow().environment(state)
                .appTheme()
                .environment(\.locale, L10n.locale)
                .id(language + String(localeRevision))
                .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
                    localeRevision += 1
                }
                .task { await state.start() }        }
        .defaultSize(width: 1080, height: 740)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .sidebar) {
                ForEach(Array(NavigationPage.primary.enumerated()), id: \.element) { index, page in
                    Button(page.title) { state.page = page }.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                        .disabled(!state.startupAccess.isReady)
                }
                Divider()
                Button(L10n.tr("Search…")) { state.showQuickFind = true }.keyboardShortcut("k").disabled(!state.startupAccess.isReady)
                Button(L10n.tr("Refresh")) { Task { await state.refreshLocalRecords() } }.keyboardShortcut("r").disabled(!state.startupAccess.isReady)
            }
            CommandGroup(replacing: .help) {
                Button(L10n.tr("Report an issue")) { NSWorkspace.shared.open(ProjectLink.issues) }
                Button(L10n.tr("View latest version")) { NSWorkspace.shared.open(ProjectLink.releases) }
                Button(L10n.tr("Check for updates")) {
                    Task { await state.updates.check(manual: true) }
                    state.page = .settings; state.presentWorkbench?()
                }.disabled(state.updates.isChecking || !state.startupAccess.isReady)
            }
            CommandGroup(replacing: .appSettings) {
                Button(L10n.tr("Settings…")) { state.page = .settings }.keyboardShortcut(",").disabled(!state.startupAccess.isReady)
            }
        }

        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuPanel().environment(state)
                .appTheme()
                .environment(\.locale, L10n.locale)
                .id(language + String(localeRevision))
                .task { await state.start() }
        } label: {
            MenuBarLabel(state: state)
        }.menuBarExtraStyle(.window)
    }
}

/// Reads only what the status item shows, so other state changes leave it alone.
struct MenuBarLabel: View {
    let state: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var images = MenuBarStatusImage.Cache()
    var body: some View {
        if state.startupAccess.isReady { quotaLabel }
        else { Image(systemName: "lock").accessibilityLabel(L10n.tr("Allow access to continue")) }
    }
    private var quotaLabel: some View {
        // The local refresh updates the label without a rendering clock inside MenuBarExtra.
        let quota = state.fiveHourQuota?.percentageText ?? "—"
        let tasks = state.library.preferences.showCodeTasks ? state.codeTasks : nil
        let description = MenuBarStatusImage.description(quota: quota, reminder: state.switchReminder, tasks: tasks)
        return Image(nsImage: images.image(quota: quota, reminder: state.switchReminder, tasks: tasks,
                                           icon: StatusIcon.image, colorScheme: colorScheme, frame: state.menuBarTaskAnimation.frame))
            .renderingMode(.original).accessibilityLabel(description).help(description)
    }
}

final class SwitchAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let current = ProcessInfo.processInfo.processIdentifier
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first(where: { $0.processIdentifier != current }) {
            existing.activate(options: [.activateAllWindows]); NSApplication.shared.terminate(nil)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        WorkbenchLifecycle.shared.prepareToOpen()
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.clearKeychainAccess()
        WorkbenchLifecycle.shared.willTerminate()
    }
}
