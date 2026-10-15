import AppKit
import SwiftUI
import XCTest
@testable import ClaudeSwitch
import SwitchCore

/// Renders the README images from `--demo` data. No real account data is involved.
/// Run through `scripts/screenshots.sh`; skipped unless CLAUDE_SWITCH_SCREENSHOTS names an output folder.
@MainActor
final class ScreenshotTests: XCTestCase {
    private static let languages = ["en", "zh-Hans", "zh-Hant", "ja"]
    nonisolated private static let windowSize = NSSize(width: 1080, height: 740)
    /// Releasing a window with a bridged SwiftUI toolbar mid-run makes AppKit raise; keep them until exit.
    private static var windows: [NSWindow] = []
    private var output: URL!

    func testRenderOperationFeedback() async throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_SWITCH_SCREENSHOTS"] else {
            throw XCTSkip("Set CLAUDE_SWITCH_SCREENSHOTS to render operation results.")
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.pretendActive
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        NSApplication.shared.applicationIconImage = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns"))
        for language in ["en", "de", "zh-Hans"] {
            UserDefaults.standard.register(defaults: [L10n.preferenceKey: language])
            let state = AppState(demo: true)
            state.inventory?.warnings = []
            let target = state.library.accounts[1]
            var plan = OperationPlan(kind: .switchAccount, sourceAccountID: state.activeID,
                                     targetAccountID: target.id, configDigest: "demo", steps: [])
            let previousAccount = state.activeID
            state.inventory?.activeAccountID = target.id
            let success = OperationFeedback.completed(plan: plan, target: state.identity(target),
                                                      quota: state.quotaRows(for: target.id), result: .init())
            state.operationFeedback = success; state.message = success.text
            try save(captureWorkbench(state, dark: false), "operation-switch-\(language)", maxWidth: 1600)
            plan.kind = .migrate; plan.conversationIDs = ["fixture-a", "fixture-b"]
            plan.transferModes = ["fixture-b": .copy]
            let transferred = OperationFeedback.completed(plan: plan, target: state.identity(target), quota: [], result: .init())
            state.operationFeedback = transferred; state.message = transferred.text
            try save(captureWorkbench(state, dark: false), "operation-transfer-\(language)", maxWidth: 1600)
            state.inventory?.activeAccountID = previousAccount
            let failure = OperationFeedback.failed(kind: .switchAccount, target: state.identity(target),
                reason: L10n.tr("The operation did not finish. Use Recover in Settings before trying again."))
            state.operationFeedback = failure; state.message = failure.text
            try save(captureWorkbench(state, dark: false), "operation-failed-\(language)", maxWidth: 1600)
            try save(captureWorkbench(state, dark: true, size: NSSize(width: 860, height: 660)),
                     "operation-failed-narrow-\(language)", maxWidth: 1400)
        }
    }

    func testRenderUpdateSettings() async throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_SWITCH_SCREENSHOTS"] else {
            throw XCTSkip("Set CLAUDE_SWITCH_SCREENSHOTS to render update settings.")
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.pretendActive
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("Resources/Info.plist")), format: nil) as! [String: Any]
        let version = info["CFBundleShortVersionString"] as! String
        for language in ["en", "de", "zh-Hans"] {
            UserDefaults.standard.register(defaults: [L10n.preferenceKey: language])
            for available in [false, true] {
                let suite = "ClaudeSwitchUpdateScreenshots." + UUID().uuidString
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let updates = AppUpdates(demo: false, currentVersion: available ? "0.1.0" : version, defaults: defaults,
                                         fetch: { ReleaseVersion(version)! })
                await updates.check(manual: true)
                let view = Form {
                    Section(L10n.tr("Updates")) { UpdateSettingsView(updates: updates) }
                    Section(L10n.tr("About")) { Link(L10n.tr("Report an issue"), destination: ProjectLink.issues) }
                }.formStyle(.grouped).padding(12).frame(width: 540, height: 460)
                try save(captureSheet(view), "update-settings-\(available ? "available" : "current")-\(language)", maxWidth: 1100)
            }
        }
    }

    func testRenderReadmeImages() throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_SWITCH_SCREENSHOTS"] else {
            throw XCTSkip("Set CLAUDE_SWITCH_SCREENSHOTS to an output folder to render the README images.")
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.pretendActive
        NSApplication.shared.applicationIconImage = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns"))

        for language in Self.languages {
            UserDefaults.standard.register(defaults: [L10n.preferenceKey: language])
            let state = AppState(demo: true)
            spin(0.3)
            // The demo's "sample data" notice is for people running --demo, not for screenshots.
            state.inventory?.warnings = []
            let status = state.fiveHourQuota?.percentageText ?? "—"
            for dark in [false, true] {
                let mode = dark ? "dark" : "light"
                state.page = .accounts
                state.selectedSessionIDs = []
                let accounts = try captureWorkbench(state, dark: dark)
                let menu = try captureMenu(state, dark: dark)
                try save(render(HeroImage(window: accounts, menu: menu, status: status, dark: dark), size: HeroImage.size),
                         "hero-\(language)-\(mode)", maxWidth: 1800, jpeg: true)
                guard language == "en" else { continue }
                try save(accounts, "accounts-\(mode)", maxWidth: 1600)
                try save(menu, "menu-\(mode)", maxWidth: 700)
                state.page = .conversations
                state.selectedSessionIDs = ["demo-1"]
                try save(captureWorkbench(state, dark: dark), "conversations-\(mode)", maxWidth: 1600)
                state.page = .usage
                try save(captureWorkbench(state, dark: dark, size: NSSize(width: 1080, height: 980), settle: 2),
                         "usage-\(mode)", maxWidth: 1600)
            }
        }
    }

    // MARK: Capture

    func testRenderSocialPreview() throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_SWITCH_SCREENSHOTS"] else {
            throw XCTSkip("Set CLAUDE_SWITCH_SCREENSHOTS to render the social preview.")
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.pretendActive
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        NSApplication.shared.applicationIconImage = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns"))
        let previousReset = UserDefaults.standard.object(forKey: Format.showResetTimeKey) as? Bool ?? true
        UserDefaults.standard.register(defaults: [L10n.preferenceKey: "en", Format.showResetTimeKey: false])
        defer { UserDefaults.standard.register(defaults: [Format.showResetTimeKey: previousReset]) }
        let state = AppState(demo: true)
        state.inventory?.warnings = []
        let menu = try captureMenu(state, dark: false)
        try save(render(SocialPreview(menu: menu), size: NSSize(width: 1280, height: 640), scale: 1),
                 "social-preview", maxWidth: 1280)
    }

    func testRenderSwitchReminders() async throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_SWITCH_SCREENSHOTS"] else {
            throw XCTSkip("Set CLAUDE_SWITCH_SCREENSHOTS to render switch reminders.")
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.pretendActive
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        NSApplication.shared.applicationIconImage = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns"))
        for language in ["en", "de", "zh-Hans", "zh-Hant", "ja"] {
            UserDefaults.standard.register(defaults: [L10n.preferenceKey: language])
            let state = AppState(demo: true)
            state.inventory?.warnings = []
            state.updateSwitchReminder()
            let reminder = try XCTUnwrap(state.switchReminder)
            try save(captureWorkbench(state, dark: false), "switch-reminder-\(language)", maxWidth: 1600)
            try save(captureMenu(state, dark: false), "switch-reminder-menu-\(language)", maxWidth: 700)
            try save(render(MenuBarLabel(state: state).padding(8).background(Color.white), size: NSSize(width: 150, height: 34)),
                     "switch-reminder-status-\(language)", maxWidth: 300)
            state.presentWorkbench = nil
            await state.reviewSwitchReminder(reminder.id)
            let operation = try XCTUnwrap(state.pending)
            try save(captureSheet(OperationSheet(operation: operation).environment(state)),
                     "switch-reminder-confirm-\(language)", maxWidth: 1100)
            state.pending = nil; state.page = .settings
            try save(captureWorkbench(state, dark: false, size: NSSize(width: 1080, height: 1320)),
                     "notification-settings-\(language)", maxWidth: 1600)
        }
    }

    func testRenderNewAccountFollowUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_SWITCH_SCREENSHOTS"] else {
            throw XCTSkip("Set CLAUDE_SWITCH_SCREENSHOTS to render the new-account follow-up.")
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.pretendActive
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        NSApplication.shared.applicationIconImage = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns"))
        for language in ["en", "de", "zh-Hans", "zh-Hant", "ja"] {
            UserDefaults.standard.register(defaults: [L10n.preferenceKey: language])
            let state = AppState(demo: true)
            try save(captureSheet(AddAccountSheet().environment(state)),
                     "add-account-follow-\(language)", maxWidth: 1000)
            state.beginNewAccountFollowUp(sourceAccountID: state.activeID)
            let target = state.library.accounts[1]
            state.inventory?.activeAccountID = target.id
            state.inventory?.warnings = []
            await state.acceptNewAccountLogin(target)
            try save(captureWorkbench(state, dark: false), "new-account-follow-waiting-\(language)", maxWidth: 1600)
            try save(captureMenu(state, dark: false), "new-account-follow-menu-\(language)", maxWidth: 700)
            state.library.accounts[1].confirmOrganization(try XCTUnwrap(target.organizationID), at: Date())
            await state.advanceNewAccountFollowUp()
            let operation = try XCTUnwrap(state.pending)
            try save(captureSheet(OperationSheet(operation: operation).environment(state)),
                     "new-account-follow-confirm-\(language)", maxWidth: 1100)
            state.pending = nil
            try save(captureWorkbench(state, dark: false), "new-account-follow-review-\(language)", maxWidth: 1600)
        }
    }

    func testRenderRankedAccounts() throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_SWITCH_SCREENSHOTS"] else {
            throw XCTSkip("Set CLAUDE_SWITCH_SCREENSHOTS to render ranked accounts.")
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.pretendActive
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        NSApplication.shared.applicationIconImage = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns"))
        for language in ["en", "de", "zh-Hans"] {
            UserDefaults.standard.register(defaults: [L10n.preferenceKey: language])
            let state = AppState(demo: true)
            state.inventory?.warnings = []
            try save(captureWorkbench(state, dark: false, size: NSSize(width: 920, height: 900)),
                     "ranked-accounts-\(language)", maxWidth: 1600)
            try save(captureMenu(state, dark: false), "ranked-menu-\(language)", maxWidth: 700)
        }
    }

    func testRenderResetRankedAccounts() throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_SWITCH_SCREENSHOTS"] else {
            throw XCTSkip("Set CLAUDE_SWITCH_SCREENSHOTS to render reset-aware ranking.")
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.pretendActive
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        NSApplication.shared.applicationIconImage = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns"))
        for language in ["en", "de", "zh-Hans"] {
            UserDefaults.standard.register(defaults: [L10n.preferenceKey: language])
            let state = AppState(demo: true), now = Date()
            state.inventory?.warnings = []
            for (index, left, reset) in [(1, 80.0, 1800.0), (3, 82.0, 14400.0)] {
                let account = state.library.accounts[index], organization = try XCTUnwrap(account.organizationID)
                state.library.accounts[index].observePlan("Max 5x", organizationID: organization, at: now, verified: true)
                state.library.usage[account.id] = UsageSnapshot(accountID: account.id, organizationID: organization,
                    observedAt: now, origin: .live, windows: [
                        QuotaWindow(id: "five_hour", title: L10n.quotaTitle("five_hour", fallback: "five_hour"),
                                    usedPercent: 100-left, resetsAt: now.addingTimeInterval(reset)),
                        QuotaWindow(id: "seven_day", title: L10n.quotaTitle("seven_day", fallback: "seven_day"),
                                    usedPercent: 20, resetsAt: now.addingTimeInterval(6*86400))])
            }
            state.inventory?.accounts = state.library.accounts
            let ranking = state.accountRanking(now: now)
            XCTAssertEqual(ranking.bestBackup?.account.id, state.library.accounts[1].id)
            XCTAssertEqual(ranking.advice?.accountID, state.library.accounts[1].id)
            try save(captureWorkbench(state, dark: false, size: NSSize(width: 920, height: 900)),
                     "reset-ranked-accounts-\(language)", maxWidth: 1600)
            try save(captureMenu(state, dark: false), "reset-ranked-menu-\(language)", maxWidth: 700)
        }
    }

    func testRenderPausedStaleQuota() throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_SWITCH_SCREENSHOTS"] else {
            throw XCTSkip("Set CLAUDE_SWITCH_SCREENSHOTS to render paused quota refresh.")
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.pretendActive
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        NSApplication.shared.applicationIconImage = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns"))
        for language in ["en", "de", "zh-Hans"] {
            UserDefaults.standard.register(defaults: [L10n.preferenceKey: language])
            let state = AppState(demo: true), now = Date()
            state.inventory?.warnings = []
            state.quotaRefreshPause = .claudeClosed
            for (index, account) in state.library.accounts.enumerated() {
                var snapshot = try XCTUnwrap(state.library.usage[account.id])
                snapshot.observedAt = now.addingTimeInterval(-10800)
                for i in snapshot.windows.indices {
                    snapshot.windows[i].observedAt = snapshot.observedAt
                    if index == 2, snapshot.windows[i].id == "five_hour" {
                        snapshot.windows[i].resetsAt = now.addingTimeInterval(-1800)
                    }
                }
                state.library.usage[account.id] = snapshot
            }
            XCTAssertNil(state.switchAdvice())
            XCTAssertTrue(state.library.accounts.allSatisfy { account in
                state.quotaRows(for: account.id).allSatisfy { $0.percentageText != "—" }
            })
            try save(captureWorkbench(state, dark: false, size: NSSize(width: 920, height: 1050)),
                     "quota-paused-\(language)", maxWidth: 1600)
            try save(captureMenu(state, dark: false), "quota-paused-menu-\(language)", maxWidth: 700)
            if language == "zh-Hans" {
                let cached = state.library.usage
                state.quotaRefreshPause = nil
                try save(captureWorkbench(state, dark: false, size: NSSize(width: 920, height: 1050)),
                         "quota-resumed-cache-\(language)", maxWidth: 1600)
                try save(captureMenu(state, dark: false), "quota-resumed-cache-menu-\(language)", maxWidth: 700)
                XCTAssertEqual(state.library.usage, cached)
            }
        }
    }

    func testRenderMissingAccountEmail() throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_SWITCH_SCREENSHOTS"] else {
            throw XCTSkip("Set CLAUDE_SWITCH_SCREENSHOTS to render the missing-email state.")
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.pretendActive
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        NSApplication.shared.applicationIconImage = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns"))
        for language in ["en", "de", "zh-Hans"] {
            UserDefaults.standard.register(defaults: [L10n.preferenceKey: language])
            let state = AppState(demo: true)
            state.inventory?.warnings = []
            let id = try XCTUnwrap(state.activeID)
            for index in state.library.accounts.indices where state.library.accounts[index].id == id {
                state.library.accounts[index].email = nil
            }
            if let index = state.inventory?.accounts.firstIndex(where: { $0.id == id }) {
                state.inventory?.accounts[index].email = nil
            }
            try save(captureWorkbench(state, dark: false),
                     "account-email-pending-\(language)", maxWidth: 1600)
        }
    }

    func testRenderAccountPlans() throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_SWITCH_SCREENSHOTS"] else {
            throw XCTSkip("Set CLAUDE_SWITCH_SCREENSHOTS to render account plans.")
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.pretendActive
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        NSApplication.shared.applicationIconImage = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns"))
        for language in ["en", "de", "zh-Hans"] {
            UserDefaults.standard.register(defaults: [L10n.preferenceKey: language])
            let state = AppState(demo: true)
            state.inventory?.warnings = []
            let free = state.library.accounts[0].id, unknown = state.library.accounts[1].id
            for index in state.library.accounts.indices {
                let id = state.library.accounts[index].id
                if id == free { state.library.accounts[index].plan = "Free" }
                if id == unknown { state.library.accounts[index].plan = nil }
                if id == free || id == unknown { state.library.usage[id] = nil }
            }
            state.inventory?.accounts = state.library.accounts
            try save(captureWorkbench(state, dark: false), "account-plans-\(language)", maxWidth: 1600)
            try save(captureMenu(state, dark: false), "account-plans-menu-\(language)", maxWidth: 700)
        }
    }

    func testRenderUsageLayout() throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_SWITCH_SCREENSHOTS"] else {
            throw XCTSkip("Set CLAUDE_SWITCH_SCREENSHOTS to render usage layouts.")
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.pretendActive
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        NSApplication.shared.applicationIconImage = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns"))
        for language in ["en", "de"] {
            UserDefaults.standard.register(defaults: [L10n.preferenceKey: language])
            let state = AppState(demo: true)
            state.page = .usage
            let width: CGFloat = language == "de" ? 920 : 1080
            for dark in [false, true] where language == "en" || !dark {
                let name = language == "de" ? "usage-narrow-de" : "usage-\(dark ? "dark" : "light")"
                try save(captureWorkbench(state, dark: dark, size: NSSize(width: width, height: 980), settle: 2),
                         name, maxWidth: 1600)
            }
        }
    }

    func testRenderLoginDiscoveryStates() throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_SWITCH_SCREENSHOTS"] else {
            throw XCTSkip("Set CLAUDE_SWITCH_SCREENSHOTS to render login discovery states.")
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.pretendActive
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        NSApplication.shared.applicationIconImage = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns"))
        for language in ["en", "de", "zh-Hans"] {
            UserDefaults.standard.register(defaults: [L10n.preferenceKey: language])
            let state = AppState(demo: true)
            let id = try XCTUnwrap(state.activeID)
            state.inventory?.warnings = []; state.awaitingNewLogin = true
            state.inventory?.activeAccountID = nil; state.inventory?.signedIn = false
            try save(captureWorkbench(state, dark: false), "login-waiting-\(language)", maxWidth: 1600)
            state.inventory?.activeAccountID = id; state.inventory?.signedIn = true
            for index in state.library.accounts.indices where state.library.accounts[index].id == id {
                state.library.accounts[index].hasSnapshot = false
            }
            XCTAssertTrue(state.activeUnsaved)
            state.loginSaveError = L10n.tr("Claude kept writing its data while the login was being copied. Try again in a moment.")
            try save(captureWorkbench(state, dark: false), "login-save-retry-\(language)", maxWidth: 1600)
        }
    }

    func testRenderStartupAccess() async throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_SWITCH_SCREENSHOTS"] else {
            throw XCTSkip("Set CLAUDE_SWITCH_SCREENSHOTS to render startup authorization.")
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.pretendActive
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        NSApplication.shared.applicationIconImage = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns"))
        for language in ["en", "zh-Hans", "de"] {
            UserDefaults.standard.register(defaults: [L10n.preferenceKey: language])
            let access = StartupAccess()
            let state = AppState(demo: true, startupAccess: access)
            await access.check(using: { item, _ in if item == .vault { throw CancellationError() } }, notificationChoice: { true }, start: { XCTFail("Startup must stay blocked") })
            let window = try captureWorkbench(state, dark: false)
            XCTAssertEqual(window.size.width, Self.windowSize.width, accuracy: 1)
            XCTAssertEqual(window.size.height, Self.windowSize.height, accuracy: 1)
            try save(window, "startup-access-\(language)", maxWidth: 1600)
            try save(captureMenu(state, dark: false), "startup-access-menu-\(language)", maxWidth: 700)
            await access.authorize(using: { item, _ in if item == .vault { throw CancellationError() } }, start: { XCTFail("Startup must stay blocked") })
            let retry = try captureWorkbench(state, dark: false)
            XCTAssertEqual(retry.size.width, Self.windowSize.width, accuracy: 1)
            XCTAssertEqual(retry.size.height, Self.windowSize.height, accuracy: 1)
            try save(retry, "startup-access-retry-\(language)", maxWidth: 1600)
            let notifications = StartupAccess()
            let notificationState = AppState(demo: true, startupAccess: notifications)
            await notifications.check(using: { _, _ in }, notificationChoice: { true }, start: { XCTFail("Notification choice must be shown") })
            XCTAssertTrue(notifications.wantsNotifications)
            try save(captureWorkbench(notificationState, dark: false), "startup-notifications-\(language)", maxWidth: 1600)
        }
    }

    func testRenderQuotaSettings() throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_SWITCH_SCREENSHOTS"] else {
            throw XCTSkip("Set CLAUDE_SWITCH_SCREENSHOTS to render quota settings.")
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.pretendActive
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        NSApplication.shared.applicationIconImage = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns"))
        for language in ["en", "de", "zh-Hans"] {
            UserDefaults.standard.register(defaults: [L10n.preferenceKey: language])
            let state = AppState(demo: true)
            state.page = .settings
            try save(captureWorkbench(state, dark: false, size: NSSize(width: 1080, height: 900), settle: 3),
                     "quota-settings-\(language)", maxWidth: 1600)
        }
    }

    func testRenderQuotaRecoveryStates() throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_SWITCH_SCREENSHOTS"] else {
            throw XCTSkip("Set CLAUDE_SWITCH_SCREENSHOTS to render quota recovery states.")
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.pretendActive
        for language in ["en", "de"] {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            NSApplication.shared.applicationIconImage = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns"))
            UserDefaults.standard.register(defaults: [L10n.preferenceKey: language])
            let state = AppState(demo: true)
            state.inventory?.warnings = []
            for (index, account) in state.accounts.enumerated() {
                guard var snapshot = state.library.usage[account.id] else { continue }
                let date = Date().addingTimeInterval(-3600)
                snapshot.observedAt = date
                for i in snapshot.windows.indices {
                    snapshot.windows[i].observedAt = date
                    if index == 0 { snapshot.windows[i].resetsAt = Date().addingTimeInterval(-60) }
                }
                state.library.usage[account.id] = snapshot
            }
            if let id = state.activeID { state.usageNotices[id] = L10n.tr("Please check that you are signed in to this account in Claude, then refresh quota.") }
            try save(captureWorkbench(state, dark: false), "quota-states-\(language)", maxWidth: 1600)
            try save(captureMenu(state, dark: false), "quota-menu-\(language)", maxWidth: 700)
            state.quotaAccessRequired = true
            try save(captureWorkbench(state, dark: false), "quota-access-\(language)", maxWidth: 1600)
            try save(captureMenu(state, dark: false), "quota-access-menu-\(language)", maxWidth: 700)
        }
    }

    private func captureWorkbench(_ state: AppState, dark: Bool, size: NSSize = windowSize, settle: TimeInterval = 1.2) throws -> NSImage {
        let controller = NSHostingController(rootView: MainWindow().environment(state).environment(\.locale, L10n.locale)
            .environment(\.controlActiveState, .key))
        controller.sceneBridgingOptions = [.toolbars, .title]
        let frame = NSRect(origin: NSPoint(x: -6000, y: 200), size: size)
        let window = ActiveWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        window.contentViewController = controller
        window.toolbarStyle = .unified
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        Self.windows.append(window)
        defer { window.orderOut(nil) }
        spin(settle)
        window.display()
        spin(0.2)
        return try capture(window)
    }

    /// Native segmented controls need a hosting window; ImageRenderer cannot draw their AppKit views.
    private func captureSheet<Content: View>(_ content: Content) throws -> NSImage {
        let view = NSHostingView(rootView: content.environment(\.locale, L10n.locale)
            .environment(\.controlActiveState, .key).environment(\.colorScheme, .light))
        let window = ActiveWindow(contentRect: NSRect(x: -6000, y: 200, width: 480, height: 700),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        window.setContentSize(view.fittingSize)
        window.orderFrontRegardless()
        Self.windows.append(window)
        defer { window.orderOut(nil) }
        spin(0.6)
        window.display()
        return try capture(window)
    }

    private func captureMenu(_ state: AppState, dark: Bool) throws -> NSImage {
        let content = MenuPanel(automaticallyReviewReminders: false).environment(state).environment(\.locale, L10n.locale)
            .background(VisualEffect()).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        let view = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: -6000, y: 200, width: 400, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        window.setContentSize(view.fittingSize)
        window.orderFrontRegardless()
        Self.windows.append(window)
        defer { window.orderOut(nil) }
        spin(1)
        return try capture(window)
    }

    private func capture(_ window: NSWindow) throws -> NSImage {
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]) else { throw CaptureError.windowCapture }
        return NSImage(cgImage: image, size: window.frame.size)
    }

    private func render<Content: View>(_ view: Content, size: NSSize, scale: CGFloat = 2) throws -> NSImage {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = scale
        guard let image = renderer.cgImage else { throw CaptureError.composition }
        return NSImage(cgImage: image, size: size)
    }

    /// Opaque compositions are written as JPEG to keep the repository small; screenshots keep their transparent corners as PNG.
    private func save(_ image: NSImage, _ name: String, maxWidth: CGFloat, jpeg: Bool = false) throws {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw CaptureError.encoding }
        let ratio = min(1, maxWidth / CGFloat(source.width))
        let width = Int((CGFloat(source.width) * ratio).rounded()), height = Int((CGFloat(source.height) * ratio).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureError.encoding }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: scaled).representation(using: jpeg ? .jpeg : .png,
                                                                          properties: jpeg ? [.compressionFactor: 0.9] : [:])
        else { throw CaptureError.encoding }
        try data.write(to: output.appendingPathComponent(name + (jpeg ? ".jpg" : ".png")))
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private enum CaptureError: Error { case windowCapture, composition, encoding }
}

/// Draws as the focused window, so controls and window buttons use their active colors without stealing focus.
private final class ActiveWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc func _hasKeyAppearance() -> Bool { true }
    @objc func _hasMainAppearance() -> Bool { true }
}

private extension NSApplication {
    @objc var screenshotAlwaysActive: Bool { true }
    /// Within this test process only, report the app as active so AppKit draws active window chrome.
    static let pretendActive: Void = {
        guard let original = class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.isActive)),
              let replacement = class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.screenshotAlwaysActive))
        else { return }
        method_exchangeImplementations(original, replacement)
    }()
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover; view.blendingMode = .withinWindow; view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Soft wallpaper with warm glows, shared by the hero and the social preview.
private struct Backdrop: View {
    let dark: Bool
    var body: some View {
        ZStack {
            LinearGradient(colors: dark ? [Color(hex: 0x241915), Color(hex: 0x141519)] : [Color(hex: 0xFCEFE6), Color(hex: 0xEFE6F4)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { proxy in
                let size = proxy.size
                Circle().fill(Palette.brand.opacity(dark ? 0.42 : 0.34)).frame(width: size.width * 0.55)
                    .blur(radius: 120).position(x: size.width * 0.86, y: size.height * 0.12)
                Circle().fill(Color(hex: dark ? 0x6B3FA0 : 0xC9B8F0).opacity(dark ? 0.35 : 0.55)).frame(width: size.width * 0.5)
                    .blur(radius: 140).position(x: size.width * 0.12, y: size.height * 0.95)
                Circle().fill(Color(hex: dark ? 0xA0522D : 0xFFD3B0).opacity(dark ? 0.25 : 0.6)).frame(width: size.width * 0.4)
                    .blur(radius: 120).position(x: size.width * 0.3, y: size.height * 0.1)
            }
        }
    }
}

/// The main window with the menu bar panel dropping from its status item.
private struct HeroImage: View {
    static let size = NSSize(width: 1440, height: 880)
    let window: NSImage
    let menu: NSImage
    let status: String
    let dark: Bool
    private var panelX: CGFloat { Self.size.width - menu.size.width - 64 }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Backdrop(dark: dark)
            menuBar
            Image(nsImage: window).resizable().frame(width: window.size.width * 0.95, height: window.size.height * 0.95)
                .shadow(color: .black.opacity(dark ? 0.6 : 0.24), radius: 34, y: 18)
                .offset(x: 56, y: 92)
            Image(nsImage: menu).resizable().frame(width: menu.size.width, height: menu.size.height)
                .shadow(color: .black.opacity(dark ? 0.55 : 0.22), radius: 26, y: 12)
                .offset(x: panelX, y: 36)
        }
        .environment(\.colorScheme, dark ? .dark : .light)
    }
    private var menuBar: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(dark ? Color.black.opacity(0.38) : Color.white.opacity(0.5)).frame(height: 30)
            HStack(spacing: 18) {
                HStack(spacing: 5) {
                    Image(nsImage: StatusIcon.image).renderingMode(.template).resizable().frame(width: 18, height: 18)
                    Text(status).monospacedDigit()
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.primary.opacity(dark ? 0.2 : 0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Image(systemName: "magnifyingglass")
            }
            .font(.system(size: 13, weight: .medium)).foregroundStyle(dark ? .white : .black)
            .offset(x: panelX + 6)
        }
    }
}

/// 1280 × 640 card for the repository's social preview.
private struct SocialPreview: View {
    let menu: NSImage
    private let ink = Color(hex: 0x29231F)
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(hex: 0xF7F4EE)
            RoundedRectangle(cornerRadius: 200)
                .fill(Color(hex: 0xE7B99F)).frame(width: 550, height: 900)
                .rotationEffect(.degrees(18)).offset(x: 800, y: -130)
            Circle().stroke(.white.opacity(0.35), lineWidth: 1)
                .frame(width: 650, height: 650).offset(x: 720, y: -90)
            Circle().stroke(.white.opacity(0.3), lineWidth: 1)
                .frame(width: 800, height: 800).offset(x: 645, y: -165)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    if let icon = NSApplication.shared.applicationIconImage {
                        Image(nsImage: icon).resizable().frame(width: 76, height: 76)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Claude Switch").font(.system(size: 28, weight: .bold))
                        Text("Claude Desktop, in your menu bar.")
                            .font(.system(size: 18)).foregroundStyle(ink.opacity(0.65))
                    }
                }
                .padding(.leading, -8)
                Spacer().frame(height: 46)
                Text("Switch accounts.")
                    .font(.system(size: 62, weight: .bold)).tracking(-2)
                Text("Keep your flow.")
                    .font(.system(size: 62, weight: .bold)).tracking(-2)
                    .foregroundStyle(Color(hex: 0xB45532))
                Spacer().frame(height: 24)
                Text("Live quotas. Timely reminders.\nCode conversations that follow you.")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(ink.opacity(0.72)).lineSpacing(5)
                Spacer()
                HStack(spacing: 12) {
                    Text("macOS 14+").font(.system(size: 17, weight: .semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(ink.opacity(0.06), in: Capsule())
                    Text("Free & open source").font(.system(size: 17, weight: .medium))
                        .foregroundStyle(ink.opacity(0.65))
                }
            }
            .foregroundStyle(ink)
            .frame(width: 680, height: 528, alignment: .leading)
            .offset(x: 64, y: 52)
            Image(nsImage: menu).resizable().aspectRatio(contentMode: .fit)
                .frame(width: 350, height: 558)
                .shadow(color: Color(hex: 0x592B1B).opacity(0.24), radius: 24, x: 0, y: 18)
                .offset(x: 842, y: 41)
        }
        .frame(width: 1280, height: 640, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, .light)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
