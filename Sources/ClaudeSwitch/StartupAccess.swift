import Foundation
import Observation
import SwitchStorage

/// A successful permission check starts services exactly once, across both app scenes.
@MainActor
@Observable
final class StartupAccess {
    enum Item: CaseIterable { case quota, vault }
    enum Phase { case unchecked, checking, authorizationRequired, authorizing, ready }
    private(set) var phase: Phase
    private(set) var authorizationFailed = false
    private(set) var confirmedItems = Set<Item>()
    private(set) var checkingItem: Item?
    private(set) var failureMessage: String?
    private(set) var notificationChoiceNeeded = false
    var wantsNotifications = true
    var isReady: Bool { phase == .ready }
    var isBusy: Bool { phase == .unchecked || phase == .checking || phase == .authorizing }

    init(ready: Bool = false) {
        phase = ready ? .ready : .unchecked
        if ready { confirmedItems = Set(Item.allCases) }
    }

    func check(using access: (Item, Bool) async throws -> Void, notificationChoice: @escaping () async -> Bool = { false },
               start: () async -> Void) async {
        guard phase == .unchecked else { return }
        await attempt(allowPrompt: false, using: access, notificationChoice: notificationChoice, start: start)
    }
    func authorize(using access: (Item, Bool) async throws -> Void, configureNotifications: (Bool) async -> Void = { _ in },
                   start: () async -> Void) async {
        guard phase == .authorizationRequired else { return }
        await attempt(allowPrompt: true, using: access, configureNotifications: configureNotifications, start: start)
    }
    func recheck(using access: (Item, Bool) async throws -> Void, start: () async -> Void) async {
        guard phase == .ready || phase == .authorizationRequired else { return }
        await attempt(allowPrompt: false, using: access, start: start)
    }
    private func attempt(allowPrompt: Bool, using access: (Item, Bool) async throws -> Void,
                         notificationChoice: (() async -> Bool)? = nil,
                         configureNotifications: (Bool) async -> Void = { _ in }, start: () async -> Void) async {
        phase = allowPrompt ? .authorizing : .checking
        authorizationFailed = false; failureMessage = nil; confirmedItems.removeAll()
        for item in Item.allCases {
            checkingItem = item
            do {
                try Task.checkCancellation()
                try await access(item, allowPrompt)
                try Task.checkCancellation()
                confirmedItems.insert(item)
            } catch {
                await RuntimeLog.shared.record(.failed, component: .startup, level: .warning, failure: RuntimeFailure(error), detail: .keychain)
                if failureMessage == nil { failureMessage = (error as? LocalizedError)?.errorDescription }
                if allowPrompt || error is CancellationError || Task.isCancelled { break }
            }
        }
        checkingItem = nil
        if let notificationChoice { notificationChoiceNeeded = await notificationChoice() }
        guard confirmedItems.count == Item.allCases.count else {
            phase = .authorizationRequired; authorizationFailed = allowPrompt
            return
        }
        if allowPrompt && notificationChoiceNeeded {
            await configureNotifications(wantsNotifications)
            notificationChoiceNeeded = false
        }
        guard !notificationChoiceNeeded, !Task.isCancelled else { phase = .authorizationRequired; return }
        phase = .ready
        await start()
    }
}
