import Foundation
import Observation

/// A successful permission check starts services exactly once, across both app scenes.
@MainActor
@Observable
final class StartupAccess {
    enum Phase { case unchecked, checking, authorizationRequired, authorizing, ready }
    private(set) var phase: Phase
    private(set) var authorizationFailed = false
    var isReady: Bool { phase == .ready }
    var isBusy: Bool { phase == .unchecked || phase == .checking || phase == .authorizing }

    init(ready: Bool = false) { phase = ready ? .ready : .unchecked }

    func check(using access: (Bool) async throws -> Void, start: () async -> Void) async {
        guard phase == .unchecked else { return }
        await attempt(allowPrompt: false, using: access, start: start)
    }
    func authorize(using access: (Bool) async throws -> Void, start: () async -> Void) async {
        guard phase == .authorizationRequired else { return }
        await attempt(allowPrompt: true, using: access, start: start)
    }
    private func attempt(allowPrompt: Bool, using access: (Bool) async throws -> Void, start: () async -> Void) async {
        phase = allowPrompt ? .authorizing : .checking
        authorizationFailed = false
        do {
            try await access(allowPrompt)
            try Task.checkCancellation()
            phase = .ready
            await start()
        } catch {
            phase = .authorizationRequired
            authorizationFailed = allowPrompt
        }
    }
}
