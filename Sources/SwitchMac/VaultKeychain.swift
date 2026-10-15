import Foundation
import Security
import SwitchCore

/// Uses only the project's Keychain namespace; failed reads never replace an existing key.
enum VaultKeychain {
    static let service = "io.github.uiuing.claude-desktop-switch.local-vault"
    static var label: String { L10n.tr("Claude Switch · Saved Logins") }
    struct Entry {
        var status: OSStatus
        var data: Data?
        init(_ status: OSStatus, data: Data? = nil) {
            self.status = status; self.data = data
        }
    }
    static var accessError: SwitchError {
        .blocked(L10n.tr("Saved accounts are locked. Allow Keychain access and try again."))
    }
    static func load(create: Bool, lookup: (String) -> Entry, make: () throws -> Entry) throws -> Data {
        let current = lookup(service)
        guard current.status == errSecSuccess || current.status == errSecItemNotFound else { throw accessError }
        func key(_ entry: Entry) throws -> Data {
            guard entry.status == errSecSuccess, let data = entry.data, data.count == 32 else { throw accessError }
            return data
        }
        if current.status == errSecSuccess { return try key(current) }
        guard create else { throw accessError }
        let created = try make()
        if created.status == errSecDuplicateItem {
            return try load(create: false, lookup: lookup, make: make)
        }
        return try key(created)
    }
}
