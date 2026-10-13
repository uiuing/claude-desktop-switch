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
    private let service = "dev.claudeswitch.local-vault"
    public init(root: URL) { self.root = root }
    public func contains(accountID: String) -> Bool {
        guard UUID(uuidString: accountID) != nil else { return false }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(accountID + ".switchvault").path)
    }
    private func key(create: Bool) throws -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "master-v1",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound, create else {
            throw SwitchError.blocked(L10n.tr("Could not read Switch's local encryption key. Unlock Keychain first."))
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let entry: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "master-v1", kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false]
        guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else { throw SwitchError.blocked(L10n.tr("Could not create an encryption key.")) }
        return key
    }
    func seal(_ data: Data, context: String) throws -> Data {
        guard data.count <= 192 * 1024 * 1024 else { throw SwitchError.blocked(L10n.tr("The snapshot exceeds the encryption size limit.")) }
        guard let sealed = try AES.GCM.seal(data, using: key(create: true), authenticating: Data(context.utf8)).combined else {
            throw SwitchError.blocked(L10n.tr("Snapshot encryption failed."))
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
            throw SwitchError.malformed(L10n.tr("Snapshot identity verification failed. Stopped."))
        }
        for file in snapshot.files {
            guard digest(file.data) == file.sha256 else { throw SwitchError.malformed(L10n.tr("Snapshot integrity verification failed.")) }
        }
        return snapshot
    }
}
