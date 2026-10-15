import Foundation
import Security

/// Both Keychain items share the legacy interaction switch, including while a prompt is open.
final class KeychainInteraction: @unchecked Sendable {
    struct Result {
        var status: OSStatus
        var data: Data?
        init(_ status: OSStatus, data: Data? = nil) { self.status = status; self.data = data }
    }
    static let shared = KeychainInteraction(get: {
        var allowed: DarwinBoolean = true
        let status = SecKeychainGetUserInteractionAllowed(&allowed)
        return (status, allowed.boolValue)
    }, set: { SecKeychainSetUserInteractionAllowed($0) })
    private let lock = NSLock()
    private let get: () -> (OSStatus, Bool)
    private let set: (Bool) -> OSStatus

    init(get: @escaping () -> (OSStatus, Bool), set: @escaping (Bool) -> OSStatus) {
        self.get = get; self.set = set
    }
    func perform(allowPrompt: Bool, operation: (Bool) -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }
        let (status, previous) = get()
        guard status == errSecSuccess else { return Result(status) }
        let disabled = set(false)
        guard disabled == errSecSuccess else { return Result(disabled) }
        defer { _ = set(previous) }
        let silent = operation(false)
        guard allowPrompt, silent.status == errSecInteractionNotAllowed || silent.status == errSecAuthFailed else { return silent }
        let enabled = set(true)
        guard enabled == errSecSuccess else { return Result(enabled) }
        return operation(true)
    }
}
