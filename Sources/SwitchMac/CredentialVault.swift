import Foundation
import CryptoKit
import Security
import SwitchCore
import SwitchStorage

struct ArchiveFile: Codable, Sendable {
    var path: String
    var data: Data
    var sha256: String
}
struct LoginSnapshot: Codable, Sendable {
    var schema = 1
    var accountID: String
    var version: String
    var createdAt: Date
    var auth: [String: JSONValue]
    var files: [ArchiveFile]
    var directories: [String]
}

public actor CredentialVault: AccountVault {
    private let root: URL
    private nonisolated let access = KeychainKeyCache()
    private let loadKey: (Bool, Bool) throws -> Data
    public init(root: URL) {
        self.root = root
        loadKey = { allowPrompt, create in try Self.readKey(root: root, allowPrompt: allowPrompt, create: create) }
    }
    init(root: URL, loadKey: @escaping (Bool, Bool) throws -> Data) { self.root = root; self.loadKey = loadKey }
    public nonisolated func clearAccess() { access.clear() }
    public func authorizeAccess(allowPrompt: Bool) throws {
        _ = try key(create: allowPrompt, allowPrompt: allowPrompt)
    }
    public func contains(accountID: String) -> Bool {
        guard UUID(uuidString: accountID) != nil else { return false }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(accountID + ".switchvault").path)
    }
    private func key(create: Bool, allowPrompt: Bool = false) throws -> SymmetricKey {
        let data = try access.read(allowPrompt: allowPrompt) { allowed in
            let data = try loadKey(allowed, create)
            guard data.count == 32 else { throw VaultKeychain.accessError }
            return data
        }
        return SymmetricKey(data: data)
    }
    private static func readKey(root: URL, allowPrompt: Bool, create: Bool) throws -> Data {
        func identity(_ service: String) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
             kSecAttrAccount as String: "master-v1"]
        }
        return try VaultKeychain.load(create: create, lookup: { service in
            var query = identity(service)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            let result = KeychainInteraction.shared.perform(allowPrompt: allowPrompt) { interactive in
                if interactive { query.removeValue(forKey: kSecUseAuthenticationUI as String) }
                var value: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &value)
                return .init(status, data: value as? Data)
            }
            return .init(result.status, data: result.data)
        }, make: {
            try validateKeyCreation(root: root)
            let data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            var entry = identity(VaultKeychain.service)
            entry[kSecValueData as String] = data; entry[kSecAttrLabel as String] = VaultKeychain.label
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            entry[kSecAttrSynchronizable as String] = false
            let added = KeychainInteraction.shared.perform(allowPrompt: allowPrompt) { _ in .init(SecItemAdd(entry as CFDictionary, nil)) }
            return .init(added.status, data: added.status == errSecSuccess ? data : nil)
        })
    }
    static func validateKeyCreation(root: URL) throws {
        let fm = FileManager.default
        for directory in [root, root.deletingLastPathComponent().appendingPathComponent("transactions")] {
            try SafeFiles.validateAncestors(directory)
            if fm.fileExists(atPath: directory.path), !(try fm.contentsOfDirectory(atPath: directory.path)).isEmpty {
                throw SwitchError.blocked(L10n.tr("The saved-login encryption key is missing. Restore it from a backup before continuing."))
            }
        }
    }
    func seal(_ data: Data, context: String) throws -> Data {
        guard data.count <= 192 * 1024 * 1024 else { throw SwitchError.blocked(L10n.tr("Account data is too large to save. Nothing was changed.")) }
        guard let sealed = try AES.GCM.seal(data, using: key(create: true), authenticating: Data(context.utf8)).combined else {
            throw SwitchError.blocked(L10n.tr("Could not securely save the account data. Please try again."))
        }
        return sealed
    }
    func unseal(_ data: Data, context: String) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key(create: false), authenticating: Data(context.utf8))
    }
    func save(_ snapshot: LoginSnapshot) throws {
        guard UUID(uuidString: snapshot.accountID) != nil else { throw SwitchError.unsafePath }
        let data = try seal(JSONEncoder().encode(snapshot), context: "account:" + snapshot.accountID)
        try SafeFiles.privateDirectory(root)
        let target = root.appendingPathComponent(snapshot.accountID + ".switchvault")
        // Keep the previous generation so a stale login cannot silently replace the only recoverable copy.
        if FileManager.default.fileExists(atPath: target.path) {
            let previous = try SafeFiles.read(target, limit: 192 * 1024 * 1024)
            try SafeFiles.atomicWrite(previous, to: root.appendingPathComponent(snapshot.accountID + ".previous.switchvault"))
        }
        try SafeFiles.atomicWrite(data, to: target)
    }
    /// Where a build that moved removed logins aside instead of deleting them left them.
    private var removedRoot: URL { root.appendingPathComponent("removed") }
    /// Deletes the saved login and its previous generation. A marker stays until `finishRemoval`,
    /// so backups a failed removal left behind are deleted on a later launch.
    func remove(accountID: String) throws {
        guard UUID(uuidString: accountID) != nil else { throw SwitchError.unsafePath }
        let fm = FileManager.default
        try SafeFiles.privateDirectory(removedRoot)
        try SafeFiles.atomicWrite(Data(), to: removedRoot.appendingPathComponent(accountID + ".purging"))
        var files = [accountID + ".switchvault", accountID + ".previous.switchvault"].map { root.appendingPathComponent($0) }
        files += ((try? fm.contentsOfDirectory(atPath: removedRoot.path)) ?? [])
            .filter { $0.hasPrefix(accountID + ".") && !$0.hasSuffix(".purging") }.map { removedRoot.appendingPathComponent($0) }
        for url in files where fm.fileExists(atPath: url.path) {
            try SafeFiles.validateAncestors(url)
            try fm.removeItem(at: url)
        }
    }
    func finishRemoval(accountID: String) throws {
        let fm = FileManager.default
        let marker = removedRoot.appendingPathComponent(accountID + ".purging")
        if fm.fileExists(atPath: marker.path) { try fm.removeItem(at: marker) }
        if (try? fm.contentsOfDirectory(atPath: removedRoot.path))?.isEmpty == true { try fm.removeItem(at: removedRoot) }
    }
    /// Accounts left in the moved-aside folder, or whose removal stopped short of their backups,
    /// with when they were removed. The user removed them, so their copies from before then are deleted.
    func movedAsideAccounts() -> [String: Date] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: removedRoot.path)) ?? []
        var found: [String: Date] = [:]
        for name in names {
            guard let id = name.split(separator: ".").first.map({ String($0).lowercased() }), UUID(uuidString: id) != nil else { continue }
            let modified = (try? removedRoot.appendingPathComponent(name).resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            found[id] = min(found[id] ?? modified, modified)
        }
        return found
    }
    /// Deletes what the moved-aside folder holds for an account, leaving its current saved login alone.
    func clearMovedAside(accountID: String) throws {
        let fm = FileManager.default
        for name in ((try? fm.contentsOfDirectory(atPath: removedRoot.path)) ?? []) where name.hasPrefix(accountID + ".") {
            let url = removedRoot.appendingPathComponent(name)
            try SafeFiles.validateAncestors(url)
            try fm.removeItem(at: url)
        }
        if (try? fm.contentsOfDirectory(atPath: removedRoot.path))?.isEmpty == true { try fm.removeItem(at: removedRoot) }
    }
    func load(accountID: String) throws -> LoginSnapshot {
        guard UUID(uuidString: accountID) != nil else { throw SwitchError.unsafePath }
        let data = try SafeFiles.read(root.appendingPathComponent(accountID + ".switchvault"), limit: 192 * 1024 * 1024)
        let snapshot = try JSONDecoder().decode(LoginSnapshot.self, from: unseal(data, context: "account:" + accountID))
        guard snapshot.schema == 1, snapshot.accountID == accountID,
              snapshot.auth["lastKnownAccountUuid"]?.string?.lowercased() == accountID else {
            throw SwitchError.malformed(L10n.tr("The saved login belongs to a different account. The operation stopped."))
        }
        for file in snapshot.files {
            guard digest(file.data) == file.sha256 else { throw SwitchError.malformed(L10n.tr("The saved login is damaged. Sign in to this account in Claude again.")) }
        }
        return snapshot
    }
}
