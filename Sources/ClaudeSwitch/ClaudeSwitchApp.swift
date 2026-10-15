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
                }
                Divider()
                Button(L10n.tr("Search…")) { state.showQuickFind = true }.keyboardShortcut("k")
                Button(L10n.tr("Refresh")) { Task { await state.refreshLocalRecords() } }.keyboardShortcut("r")
            }
            CommandGroup(replacing: .appSettings) {
                Button(L10n.tr("Settings…")) { state.page = .settings }.keyboardShortcut(",")
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
private struct MenuBarLabel: View {
    let state: AppState
    var body: some View {
        let quota = state.fiveHourQuota?.percentageText ?? "—"
        HStack(spacing: 4) {
            Image(nsImage: StatusIcon.image)
            // A scheduled view inside the status item's rendered label can keep
            // invalidating MenuBarExtra during launch. The local refresh already
            // updates this value once a minute without a separate rendering clock.
            Text(quota).monospacedDigit()
        }.accessibilityLabel(L10n.tr("Claude Switch, current account session limit remaining: {0}", L10n.argument(quota)))
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
        AppState.shared.clearQuotaAccess()
        WorkbenchLifecycle.shared.willTerminate()
    }
}
