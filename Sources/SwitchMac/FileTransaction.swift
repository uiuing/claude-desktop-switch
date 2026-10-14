import Foundation
import Darwin
import SwitchCore
import SwitchStorage

struct TransactionEntry: Codable {
    var relative: String
    var existed: Bool
    var started = false
    var restored = false
    var expectation: FileExpectation?
}
struct TransactionJournal: Codable {
    var schema = 1
    var id: String
    var phase: String
    var sourceAccountID: String?
    var targetAccountID: String
    var createdAt: Date
    var entries: [TransactionEntry]
    /// The Claude version whose files the originals are; absent in journals written before it was recorded.
    var claudeVersion: String?
}

final class OperationLock {
    private let fd: Int32
    init(root: URL) throws {
        try SafeFiles.privateDirectory(root)
        let path = root.appendingPathComponent("operation.lock")
        try SafeFiles.validateAncestors(path)
        fd = open(path.path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SwitchError.unsafePath }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw SwitchError.busy }
    }
    deinit { flock(fd, LOCK_UN); close(fd) }
}

/// A multi-file swap is not atomic. Durable intent, retained originals, and explicit recovery make that visible.
final class FileTransaction {
    let root: URL
    let live: URL
    var journal: TransactionJournal
    private let fm = FileManager.default
    private var journalURL: URL { root.appendingPathComponent("journal.json") }
    init(parent: URL, live: URL, plan: OperationPlan, claudeVersion: String? = nil) throws {
        root = parent.appendingPathComponent(plan.id.uuidString)
        self.live = live
        journal = TransactionJournal(id: plan.id.uuidString, phase: "preparing", sourceAccountID: plan.sourceAccountID,
                                     targetAccountID: plan.targetAccountID, createdAt: Date(), entries: [],
                                     claudeVersion: claudeVersion)
        try SafeFiles.privateDirectory(root)
        for child in ["staged", "originals", "quarantine"] { try SafeFiles.privateDirectory(root.appendingPathComponent(child)) }
        try persist()
    }
    init(existing: URL, live: URL) throws {
        root = existing; self.live = live
        journal = try JSONDecoder().decode(TransactionJournal.self, from: SafeFiles.read(existing.appendingPathComponent("journal.json")))
        guard journal.schema == 1, UUID(uuidString: journal.id) != nil,
              journal.id == existing.lastPathComponent else { throw SwitchError.malformed(L10n.tr("The recovery journal format is unsupported.")) }
        for entry in journal.entries { try Self.validateAllowed(entry.relative) }
    }
    static func validateAllowed(_ relative: String) throws {
        let parts = relative.split(separator: "/")
        if IdentitySchema.containers.contains(relative) || ["config.json", "config.json.journal"].contains(relative) { return }
        guard parts.count == 4, parts[0] == "claude-code-sessions",
              UUID(uuidString: String(parts[1])) != nil, UUID(uuidString: String(parts[2])) != nil,
              String(parts[3]).hasSuffix(".json"),
              LocalID.isSession(String(parts[3].dropLast(5))) else { throw SwitchError.unsafePath }
    }
    func stage(relative: String, data: Data?, expectation: FileExpectation? = nil) throws {
        try Self.validateAllowed(relative)
        guard !journal.entries.contains(where: { $0.relative == relative }) else { throw SwitchError.malformed(L10n.tr("Duplicate transaction target.")) }
        let destination = try SafeFiles.child(relative, of: live)
        if let expectation, try MigrationBuilder.expectation(at: destination) != expectation { throw SwitchError.changed }
        journal.entries.append(.init(relative: relative, existed: fm.fileExists(atPath: destination.path), expectation: expectation))
        if let data {
            let file = try SafeFiles.child(relative, of: root.appendingPathComponent("staged"))
            try SafeFiles.privateDirectory(file.deletingLastPathComponent())
            try SafeFiles.atomicWrite(data, to: file)
        }
        try persist()
    }
    func stageContainer(_ name: String, files: [ArchiveFile], directories: [String]) throws {
        try stage(relative: name, data: nil)
        let base = root.appendingPathComponent("staged")
        for directory in directories where directory == name || directory.hasPrefix(name + "/") {
            try SafeFiles.privateDirectory(SafeFiles.child(directory, of: base))
        }
        for file in files where file.path == name || file.path.hasPrefix(name + "/") {
            let url = try SafeFiles.child(file.path, of: base)
            try SafeFiles.privateDirectory(url.deletingLastPathComponent()); try SafeFiles.atomicWrite(file.data, to: url)
        }
    }
    func persist() throws { try SafeFiles.atomicWrite(JSONEncoder().encode(journal), to: journalURL) }
    func apply(stopped: () async throws -> Void) async throws {
        try BuildAccess.requireClaudeWrites()
        journal.phase = "applying"; try persist()
        for index in journal.entries.indices {
            try await stopped()
            let relative = journal.entries[index].relative
            let target = try SafeFiles.child(relative, of: live)
            let previous = try SafeFiles.child(relative, of: root.appendingPathComponent("originals"))
            let replacement = try SafeFiles.child(relative, of: root.appendingPathComponent("staged"))
            guard fm.fileExists(atPath: target.path) == journal.entries[index].existed else { throw SwitchError.changed }
            if let expected = journal.entries[index].expectation,
               try MigrationBuilder.expectation(at: target) != expected { throw SwitchError.changed }
            journal.entries[index].started = true; try persist()
            if journal.entries[index].existed {
                try SafeFiles.privateDirectory(previous.deletingLastPathComponent())
                try fm.moveItem(at: target, to: previous)
                try SafeFiles.syncDirectory(previous.deletingLastPathComponent())
            }
            if fm.fileExists(atPath: replacement.path) {
                if !fm.fileExists(atPath: target.deletingLastPathComponent().path) {
                    try SafeFiles.privateDirectory(target.deletingLastPathComponent())
                }
                try fm.moveItem(at: replacement, to: target)
            }
            try SafeFiles.syncDirectory(target.deletingLastPathComponent())
            try persist()
        }
        journal.phase = "applied"; try persist()
    }
    func rollback(stopped: () async throws -> Void) async throws {
        try BuildAccess.requireClaudeWrites()
        try await stopped()
        journal.phase = "recovering"; try persist()
        for index in journal.entries.indices.reversed() where journal.entries[index].started && !journal.entries[index].restored {
            try await stopped()
            let entry = journal.entries[index]
            let target = try SafeFiles.child(entry.relative, of: live)
            let original = try SafeFiles.child(entry.relative, of: root.appendingPathComponent("originals"))
            let quarantine = try SafeFiles.child(entry.relative, of: root.appendingPathComponent("quarantine"))
            let originalPresent = fm.fileExists(atPath: original.path)
            // If the first rename never happened, target is still the original and must be left alone.
            if originalPresent || !entry.existed {
                if fm.fileExists(atPath: target.path) {
                    try SafeFiles.privateDirectory(quarantine.deletingLastPathComponent())
                    let retained = quarantine.appendingPathExtension(UUID().uuidString)
                    try fm.moveItem(at: target, to: retained)
                }
                if originalPresent { try fm.moveItem(at: original, to: target) }
                try SafeFiles.syncDirectory(target.deletingLastPathComponent())
            }
            journal.entries[index].restored = true; try persist()
        }
        journal.phase = "recovered"; try persist()
    }
    func commit() throws { journal.phase = "committed"; try persist() }

    /// Set once the swapped-out login was purged; the transaction no longer holds a copy of its source account.
    var sourcePurged: Bool { fm.fileExists(atPath: root.appendingPathComponent("source-purged").path) }
    /// A switch or sign-out: `originals` hold the login that was swapped out, not just session records.
    var holdsLogin: Bool { journal.entries.contains { $0.relative == "config.json" } }
    /// Deletes a finished transaction with everything it kept.
    func discard() throws {
        guard ["committed", "recovered"].contains(journal.phase) else { throw SwitchError.blocked(L10n.tr("Unfinished transactions must retain their recovery originals.")) }
        try SafeFiles.validateAncestors(root)
        try fm.removeItem(at: root)
    }
    /// Deletes one account's share of a finished transaction, on disk and inside the sealed archive:
    /// `staged` and `quarantine` hold the login swapped in, `originals` the one swapped out.
    /// The whole transaction goes once nothing else is left in it.
    func purge(_ parts: Set<String>, vault: CredentialVault) async throws {
        guard ["committed", "recovered"].contains(journal.phase) else { throw SwitchError.blocked(L10n.tr("Unfinished transactions must retain their recovery originals.")) }
        for name in parts where ["staged", "originals", "quarantine"].contains(name) {
            let folder = root.appendingPathComponent(name)
            try SafeFiles.validateAncestors(folder)
            if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
        }
        var kept = 0
        let archive = root.appendingPathComponent("recovery.switchbackup")
        if fm.fileExists(atPath: archive.path) {
            let context = "transaction:" + journal.id
            let sealed = try SafeFiles.read(archive, limit: 192 * 1024 * 1024)
            let files = try JSONDecoder().decode([ArchiveFile].self, from: try await vault.unseal(sealed, context: context))
            let remaining = files.filter { !parts.contains(String($0.path.split(separator: "/").first ?? "")) }
            if remaining.isEmpty { try fm.removeItem(at: archive) }
            else if remaining.count != files.count {
                let resealed = try await vault.seal(JSONEncoder().encode(remaining), context: context)
                try SafeFiles.atomicWrite(resealed, to: archive)
            }
            kept = remaining.count
        }
        let loose = ["staged", "originals", "quarantine"].contains { name in
            let folder = root.appendingPathComponent(name)
            return (fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? [])
                .contains { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        }
        if kept == 0 && !loose {
            try SafeFiles.validateAncestors(root)
            try fm.removeItem(at: root)
        } else if parts.contains("originals") {
            try SafeFiles.atomicWrite(Data(), to: root.appendingPathComponent("source-purged"))
        }
    }

    func archive(vault: CredentialVault) async throws {
        try BuildAccess.requireClaudeWrites()
        guard ["committed", "recovered"].contains(journal.phase) else { throw SwitchError.blocked(L10n.tr("Unfinished transactions must retain their recovery originals.")) }
        var files: [ArchiveFile] = [], size = 0
        func collect(_ directory: URL, prefix: String, depth: Int) throws {
            guard depth < 20, files.count < 25_000 else { throw SwitchError.blocked(L10n.tr("The recovery archive exceeds the limit.")) }
            try SafeFiles.validateAncestors(directory)
            for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                let properties = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard properties.isSymbolicLink != true else { throw SwitchError.unsafePath }
                let path = prefix + "/" + file.lastPathComponent
                if properties.isDirectory == true { try collect(file, prefix: path, depth: depth + 1) }
                else {
                    let data = try SafeFiles.read(file, limit: 64 * 1024 * 1024); size += data.count
                    guard size <= 128 * 1024 * 1024 else { throw SwitchError.blocked(L10n.tr("The recovery archive exceeds the limit.")) }
                    files.append(ArchiveFile(path: path, data: data, sha256: digest(data)))
                }
            }
        }
        for name in ["staged", "originals", "quarantine"] {
            let folder = root.appendingPathComponent(name)
            if fm.fileExists(atPath: folder.path) { try collect(folder, prefix: name, depth: 0) }
        }
        guard !files.isEmpty else { return }
        let data = try JSONEncoder().encode(files), context = "transaction:" + journal.id
        let sealed = try await vault.seal(data, context: context)
        let archive = root.appendingPathComponent("recovery.switchbackup")
        try SafeFiles.atomicWrite(sealed, to: archive)
        let restored = try await vault.unseal(SafeFiles.read(archive, limit: 192 * 1024 * 1024), context: context)
        guard digest(restored) == digest(data) else { throw SwitchError.blocked(L10n.tr("Recovery archive verification failed. Originals are preserved.")) }
        // These are transaction-owned scratch folders, never Claude's live directories.
        for name in ["staged", "originals", "quarantine"] {
            let folder = root.appendingPathComponent(name)
            try SafeFiles.validateAncestors(folder)
            if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
        }
        try SafeFiles.syncDirectory(root)
    }
}
