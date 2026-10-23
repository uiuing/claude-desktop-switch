import Foundation
import SwitchCore

enum NotificationDestination { case accounts, recommendation(UUID) }

extension AppState {
    /// Uses existing online measurements only; reminders never trigger another quota request.
    func updateSwitchReminder(now: Date = Date(), notify: Bool = true) {
        reminderExpiration?.cancel(); reminderExpiration = nil
        guard startupAccess.isReady, !working, inventory?.signedIn == true, recoveryIDs.isEmpty else {
            switchReminder = nil; notifications.removeRecommendation(); return
        }
        let decision = reminderPolicy.evaluate(accountRanking(now: now), now: now)
        switchReminder = decision?.reminder
        saveReminderReceipts()
        notifications.reconcileRecommendation(switchReminder?.needsReview == true ? switchReminder?.id : nil)
        guard let decision else { return }
        let reminder = decision.reminder
        if notify, decision.shouldNotify, demo || quotaRefreshPause != .claudeClosed {
            Task { [weak self] in
                guard let self, self.switchReminder?.id == reminder.id, self.switchReminder?.needsReview == true else { return }
                await self.notifications.showRecommendation(reminder)
            }
        }
        reminderExpiration = Task { [weak self] in
            let delay = max(0.1, reminder.expiresAt.timeIntervalSince(now) + 0.1)
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.updateSwitchReminder()
        }
    }
    private func saveReminderReceipts() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard !demo, let data = try? encoder.encode(reminderPolicy),
              UserDefaults.standard.data(forKey: "switchReminderReceipts") != data else { return }
        UserDefaults.standard.set(data, forKey: "switchReminderReceipts")
    }
    func dismissSwitchReminder() {
        guard let id = switchReminder?.id else { return }
        reminderPolicy.acknowledge(id)
        notifications.removeRecommendation()
        updateSwitchReminder(notify: false)
    }
    func reviewSwitchReminder(_ id: UUID) async {
        page = .accounts
        presentWorkbench?()
        guard startupAccess.isReady, !working, !reviewingReminder, pending == nil,
              !showAddAccount, !showQuickFind, !preparingNewAccountFollowUp else { return }
        updateSwitchReminder(notify: false)
        guard let reminder = switchReminder, reminder.id == id,
              let suggested = switchAdvice(), suggested.account.id == reminder.targetAccountID,
              activeID == reminder.sourceAccountID else {
            message = L10n.tr("This recommendation is no longer current. Review the latest account quotas.")
            return
        }
        reviewingReminder = true
        defer { reviewingReminder = false }
        dismissSwitchReminder()
        let sourceID = activeID
        let sessions = SessionLibrary.followedSessions(inventory?.conversations ?? [], rules: library.follows,
            activeAccountID: sourceID, targetAccountID: suggested.account.id)
        do {
            let operation = try await makeSwitchOperation(target: suggested.account, followed: sessions)
            // Preparation may suspend while Claude changes accounts or another window opens a sheet.
            guard startupAccess.isReady, !working, inventory?.signedIn == true, recoveryIDs.isEmpty,
                  activeID == sourceID, pending == nil, !showAddAccount, !showQuickFind,
                  switchAdvice()?.account.id == suggested.account.id else {
                message = L10n.tr("This recommendation is no longer current. Review the latest account quotas.")
                return
            }
            message = nil
            pending = operation
        } catch { message = display(error) }
    }
    func openNotification(_ id: UUID?) async {
        notificationDestination = id.map(NotificationDestination.recommendation) ?? .accounts
        presentWorkbench?()
        await start()
        await openPendingNotification()
    }
    func openPendingNotification() async {
        guard startupAccess.isReady, servicesLoaded || demo, presentWorkbench != nil,
              let destination = notificationDestination else { return }
        notificationDestination = nil
        page = .accounts; presentWorkbench?()
        if case .recommendation(let id) = destination { await reviewSwitchReminder(id) }
    }
    func enableNotifications() async {
        await notifications.setEnabled(true)
        updateSwitchReminder(notify: false)
        if let reminder = switchReminder, reminder.needsReview { await notifications.showRecommendation(reminder) }
    }
}
