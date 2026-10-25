import AppKit
import Foundation
import SwitchCore

extension AppState {
    func updateMenuBarTaskAnimation() {
        menuBarTaskAnimation.setRunning(startupAccess.isReady && desktopAwake && !working &&
            library.preferences.showCodeTasks && (codeTasks.running ?? 0) > 0)
    }
    var codeTaskScope: CodeTaskScope? {
        guard inventory?.signedIn == true, let id = activeID,
              let org = knownAccounts.first(where: { $0.id == id })?.organizationID else { return nil }
        return CodeTaskScope(accountID: id, organizationID: org)
    }
    var codeTasks: CodeTaskSnapshot {
        if working { return .init(availability: .switching) }
        if [.offline, .unavailable].contains(codeTaskBinding.snapshot.availability), codeTaskBinding.snapshot.scope == nil {
            return codeTaskBinding.snapshot
        }
        guard let scope = codeTaskScope else { return .init(availability: .unavailable) }
        guard codeTaskBinding.snapshot.scope == scope else { return .init(availability: .connecting) }
        return codeTaskBinding.snapshot
    }
    func startCodeTaskPolling() {
        guard !demo, codeTaskPolling == nil else { return }
        codeTaskPolling = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                await self?.refreshCodeTasks()
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                if self == nil { return }
            }
        }
    }
    func refreshCodeTasks() async {
        guard !demo, desktopAwake, startupAccess.isReady, library.preferences.showCodeTasks, !working,
              !codeTasksNeedInventory, !readingCodeTasks, let scope = codeTaskScope else { return }
        readingCodeTasks = true; defer { readingCodeTasks = false }
        let ticket = codeTaskBinding.begin(scope)
        let followed = (inventory?.conversations ?? []).filter { session in library.follows.contains { $0.matches(session) } }
        let result = await codeTaskSource.scan(scope: scope, followed: followed)
        guard desktopAwake, !working, !codeTasksNeedInventory, startupAccess.isReady, library.preferences.showCodeTasks, codeTaskScope == scope else { return }
        codeTaskBinding.accept(result, for: ticket)
    }
    func setCodeTasksEnabled(_ enabled: Bool) {
        library.preferences.showCodeTasks = enabled
        codeTaskBinding.invalidate(enabled ? .connecting : .unavailable)
        if demo && enabled { installDemoCodeTasks() }
        persist()
        if enabled { Task { await refreshCodeTasks() } }
    }
    func installDemoCodeTasks() {
        guard demo, let scope = codeTaskScope else { return }
        let sessions = (inventory?.conversations ?? []).filter(scope.contains)
        let states: [CodeTaskStatus] = [.running, .permission, .idle]
        let tasks = sessions.enumerated().map { index, session in
            CodeTask(conversation: session, status: states[index % states.count])
        }
        let ticket = codeTaskBinding.begin(scope)
        codeTaskBinding.accept(.init(scope: scope, availability: .ready, tasks: tasks), for: ticket)
        codeTasksNeedInventory = false
    }
    func canOpenCodeTask(_ task: CodeTask) -> Bool {
        library.preferences.showCodeTasks && !working && !openingCodeTask && task.destination != nil && codeTaskScope?.contains(task.conversation) == true &&
            codeTasks.tasks.contains(where: { conversationTree.root(of: $0.conversation).id == task.id }) && (demo || BuildAccess.allowsClaudeWrites)
    }
    func openCodeTask(_ task: CodeTask) async {
        guard canOpenCodeTask(task) else { return }
        if demo {
            message = L10n.tr("Demo: this conversation would open in Claude. No app was opened.")
            return
        }
        guard startupAccess.isReady, BuildAccess.allowsClaudeWrites, library.preferences.showCodeTasks,
              !codeTasksNeedInventory, let scope = codeTaskScope else { return }
        openingCodeTask = true; defer { openingCodeTask = false }
        let ticket = codeTaskBinding.begin(scope)
        // Re-read the current account and selected index before dispatching a link with no account component.
        let result = await codeTaskSource.scan(scope: scope, followed: [task.conversation])
        guard desktopAwake, startupAccess.isReady, !working, !codeTasksNeedInventory, codeTaskScope == scope, library.preferences.showCodeTasks,
              codeTaskBinding.isCurrent(ticket), result.scope == scope,
              let current = result.tasks.first(where: { $0.id == task.id }), let url = current.destination,
              let application = environment.application else {
            message = L10n.tr("The conversation changed. Refresh and try again."); return
        }
        do {
            try BuildAccess.requireClaudeWrites()
            let config = NSWorkspace.OpenConfiguration(); config.activates = true
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: application, configuration: config)
        } catch { message = L10n.tr("Could not open this conversation in Claude.") }
    }
}
