import AppKit
import Observation
import SwitchCore
import UserNotifications

@MainActor
@Observable
final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
    enum Access { case unavailable, notDetermined, allowed, denied }
    private(set) var access: Access = .unavailable
    private(set) var enabled = false
    private(set) var requesting = false
    private(set) var failed = false
    var needsStartupChoice: Bool {
        access == .notDetermined && defaults?.bool(forKey: "notifications.startupChoiceMade") != true
    }
    var completions = true { didSet { savePreferences() } }
    var recommendations = true { didSet {
        savePreferences()
        if !recommendations { removeRecommendation() }
    } }
    @ObservationIgnored var onOpen: ((UUID?) async -> Void)?
    @ObservationIgnored private let center: UNUserNotificationCenter?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var currentReminderID: UUID?
    @ObservationIgnored private var reconciled = false
    private static let recommendationID = "switch-recommendation"
    private static let completionID = "switch-completed"
    private static let reviewAction = "review-switch"

    init(demo: Bool) {
        // UNUserNotificationCenter requires an application bundle. Tests and demos never register or send.
        let available = !demo && Bundle.main.bundleURL.pathExtension == "app"
        center = available ? .current() : nil
        defaults = demo ? nil : .standard
        enabled = defaults?.bool(forKey: "notifications.enabled") ?? false
        completions = defaults?.object(forKey: "notifications.completions") as? Bool ?? true
        recommendations = defaults?.object(forKey: "notifications.recommendations") as? Bool ?? true
        super.init()
        center?.delegate = self
        configureActions()
    }
    private func configureActions() {
        let review = UNNotificationAction(identifier: Self.reviewAction, title: L10n.tr("Review switch"), options: [.foreground])
        center?.setNotificationCategories([UNNotificationCategory(identifier: "switch-recommendation", actions: [review],
            intentIdentifiers: [], options: [])])
    }
    func refreshAccess() async {
        guard let center else { return }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: access = .notDetermined
        case .authorized, .provisional, .ephemeral: access = .allowed
        case .denied: access = .denied
        @unknown default: access = .denied
        }
    }
    func setEnabled(_ value: Bool) async {
        guard !requesting else { return }
        defaults?.set(true, forKey: "notifications.startupChoiceMade")
        if !value {
            enabled = false; savePreferences(); removeRecommendation()
            center?.removeDeliveredNotifications(withIdentifiers: [Self.completionID])
            center?.removePendingNotificationRequests(withIdentifiers: [Self.completionID])
            return
        }
        guard let center else { return }
        requesting = true; failed = false
        defer { requesting = false }
        do {
            let granted = try await center.requestAuthorization(options: [.alert])
            enabled = granted; savePreferences()
        } catch { failed = true }
        await refreshAccess()
    }
    private func savePreferences() {
        defaults?.set(enabled, forKey: "notifications.enabled")
        defaults?.set(completions, forKey: "notifications.completions")
        defaults?.set(recommendations, forKey: "notifications.recommendations")
    }
    func removeRecommendation() {
        reconcileRecommendation(nil)
    }
    func reconcileRecommendation(_ requestedID: UUID?) {
        let id = enabled && recommendations ? requestedID : nil
        guard !reconciled || currentReminderID != id else { return }
        reconciled = true; currentReminderID = id
        guard let center else { return }
        Task {
            let delivered = await center.deliveredNotifications()
            let pending = await center.pendingNotificationRequests()
            let keep = currentReminderID.map { Self.recommendationID + "." + $0.uuidString }
            let obsolete = Set(delivered.map { $0.request.identifier } + pending.map(\.identifier))
                .filter { $0.hasPrefix(Self.recommendationID) && $0 != keep }
            center.removePendingNotificationRequests(withIdentifiers: Array(obsolete))
            center.removeDeliveredNotifications(withIdentifiers: Array(obsolete))
        }
    }
    func showRecommendation(_ reminder: SwitchReminder) async {
        guard enabled, recommendations, let center else { return }
        reconcileRecommendation(reminder.id)
        await refreshAccess()
        guard enabled, recommendations, access == .allowed, currentReminderID == reminder.id,
              reminder.expiresAt > Date() else { return }
        configureActions()
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.detail + " " + L10n.tr("Click to review the recommended account before switching.")
        content.categoryIdentifier = Self.recommendationID
        // The system notification contains no account identity, email, path or credential.
        content.userInfo = ["reminder": reminder.id.uuidString]
        let identifier = Self.recommendationID + "." + reminder.id.uuidString
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            failed = false
            if currentReminderID != reminder.id || !enabled || !recommendations {
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
                center.removeDeliveredNotifications(withIdentifiers: [identifier])
            }
        } catch { failed = true }
    }
    func showOperationResult(_ feedback: OperationFeedback) async {
        guard enabled, completions, let center else { return }
        await refreshAccess()
        guard enabled, completions, access == .allowed else { return }
        let content = UNMutableNotificationContent()
        content.title = feedback.title
        content.body = feedback.notificationBody
        do {
            try await center.add(UNNotificationRequest(identifier: Self.completionID, content: content, trigger: nil))
            if !enabled || !completions {
                center.removePendingNotificationRequests(withIdentifiers: [Self.completionID])
                center.removeDeliveredNotifications(withIdentifiers: [Self.completionID])
            }
        }
        catch { failed = true }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in
            let request = notification.request
            if request.identifier.hasPrefix(Self.recommendationID + ".") {
                let id = (request.content.userInfo["reminder"] as? String).flatMap(UUID.init(uuidString:))
                guard enabled, recommendations, id != nil, id == currentReminderID else { completionHandler([]); return }
            } else if !enabled || !completions { completionHandler([]); return }
            // The visible workbench already has its own reminder or completion toast.
            completionHandler(NSApp.isActive && WorkbenchLifecycle.shared.workbenchOnScreen ? [.list] : [.banner, .list])
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let request = response.notification.request
        let reminderID = (request.content.userInfo["reminder"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            defer { completionHandler() }
            guard action == UNNotificationDefaultActionIdentifier || action == Self.reviewAction else { return }
            guard request.identifier == Self.completionID || request.identifier.hasPrefix(Self.recommendationID + ".") else { return }
            if request.identifier.hasPrefix(Self.recommendationID + "."), reminderID == nil { return }
            await onOpen?(reminderID)
        }
    }
    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}

extension SwitchReminder {
    var title: String {
        if kind == .expiring { return L10n.tr("A better time to switch") }
        return exhausted ? L10n.tr("Quota used up") : L10n.tr("Quota running low")
    }
    var detail: String {
        switch kind {
        case .sessionLow: return L10n.tr("Session limit remaining: {0}", L10n.argument(remaining))
        case .weeklyLow: return L10n.tr("Weekly limit remaining: {0}", L10n.argument(remaining))
        case .expiring: return L10n.tr("Another account has unused quota that resets soon.")
        }
    }
}
