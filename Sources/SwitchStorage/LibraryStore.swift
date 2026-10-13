import Foundation
import SwitchCore

public actor LibraryStore {
    public let root: URL
    public init(root: URL) { self.root = root }
    public func load() throws -> LibraryState {
        let url = root.appendingPathComponent("library.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return LibraryState() }
        let state = try JSONDecoder().decode(LibraryState.self, from: SafeFiles.read(url, limit: 4 * 1024 * 1024))
        guard state.schemaVersion == 1 else { throw SwitchError.malformed(L10n.tr("This library version is unsupported. The original file is unchanged.")) }
        return state
    }
    public func save(_ state: LibraryState) throws {
        try SafeFiles.privateDirectory(root)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try SafeFiles.atomicWrite(encoder.encode(state), to: root.appendingPathComponent("library.json"))
    }
}
