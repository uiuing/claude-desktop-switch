import Foundation
import SwitchCore

public actor LibraryStore {
    public let root: URL
    public init(root: URL) { self.root = root }
    public func load() throws -> LibraryState {
        let url = root.appendingPathComponent("library.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return LibraryState() }
        var state = try JSONDecoder().decode(LibraryState.self, from: SafeFiles.read(url, limit: 4 * 1024 * 1024))
        guard state.schemaVersion == 1 else { throw SwitchError.malformed(L10n.tr("This library version is unsupported. The original file is unchanged.")) }
        // Legacy flags were inferred from cookie absence, without server revocation evidence.
        for index in state.accounts.indices { state.accounts[index].loginInvalidAt = nil }
        state.usage = state.usage.compactMapValues { $0.onlineOnly() }
        state.usageHistory = state.usageHistory.mapValues { $0.compactMap { $0.onlineOnly() } }
        return state
    }
    public func save(_ state: LibraryState) throws {
        try SafeFiles.privateDirectory(root)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try SafeFiles.atomicWrite(encoder.encode(state), to: root.appendingPathComponent("library.json"))
    }
}
