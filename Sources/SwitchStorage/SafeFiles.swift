import Foundation
import SwitchCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct FileStamp: Codable, Equatable, Sendable {
    public var inode: UInt64
    public var size: Int64
    public var modified: Date
    public var nanoseconds: Int64
}

public enum SafeFiles {
    /// Walk every component with openat. A symlinked ancestor must not redirect a read or a write.
    public static func openRead(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.pathComponents.contains("..") else { throw SwitchError.unsafePath }
        let parts = url.standardizedFileURL.pathComponents.filter { $0 != "/" }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw SwitchError.unsafePath }
        defer { close(parent) }
        for part in parts.dropLast() {
            let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw SwitchError.unsafePath }
            close(parent); parent = next
        }
        guard let name = parts.last else { throw SwitchError.unsafePath }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw SwitchError.missing(L10n.tr("Could not read the specified local file.")) }
        var s = stat()
        guard fstat(fd, &s) == 0, (s.st_mode & S_IFMT) == S_IFREG else { close(fd); throw SwitchError.unsafePath }
        return fd
    }

    public static func stamp(_ fd: Int32) throws -> FileStamp {
        var s = stat(); guard fstat(fd, &s) == 0 else { throw SwitchError.unsafePath }
        #if canImport(Darwin)
        let t = s.st_mtimespec
        #else
        let t = s.st_mtim
        #endif
        return FileStamp(inode: UInt64(s.st_ino), size: Int64(s.st_size),
                         modified: Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_nsec) / 1e9),
                         nanoseconds: Int64(t.tv_nsec))
    }

    public static func read(_ url: URL, limit: Int = 8 * 1024 * 1024) throws -> Data {
        let fd = try openRead(url)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let before = try stamp(fd)
        guard before.size >= 0, before.size <= limit else { throw SwitchError.blocked(L10n.tr("The file exceeds the read limit and was skipped.")) }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit, try stamp(fd) == before else { throw SwitchError.changed }
        return data
    }

    public static func json(_ url: URL, limit: Int = 8 * 1024 * 1024) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: read(url, limit: limit))
    }

    public static func children(_ url: URL) throws -> [URL] {
        try validateAncestors(url)
        return try FileManager.default.contentsOfDirectory(at: url,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: [.skipsHiddenFiles])
            .filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false }
    }

    public static func validateAncestors(_ url: URL) throws {
        var path = URL(fileURLWithPath: "/", isDirectory: true)
        for c in url.standardizedFileURL.pathComponents where c != "/" {
            path.appendPathComponent(c)
            var s = stat()
            if lstat(path.path, &s) != 0 {
                if errno == ENOENT { return }
                throw SwitchError.unsafePath
            }
            guard s.st_mode & S_IFMT != S_IFLNK else { throw SwitchError.unsafePath }
        }
    }

    public static func child(_ relative: String, of root: URL) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\"),
              !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else { throw SwitchError.unsafePath }
        let url = root.appendingPathComponent(relative)
        try validateAncestors(url)
        return url
    }

    public static func privateDirectory(_ url: URL) throws {
        try validateAncestors(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try validateAncestors(url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    public static func atomicWrite(_ data: Data, to url: URL) throws {
        try validateAncestors(url)
        let parent = url.deletingLastPathComponent()
        try validateAncestors(parent)
        let dir = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw SwitchError.unsafePath }
        defer { close(dir) }
        let name = ".switch-" + UUID().uuidString + ".tmp"
        let fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SwitchError.blocked(L10n.tr("Could not create a temporary file.")) }
        var installed = false
        defer { close(fd); if !installed { unlinkat(dir, name, 0) } }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                #if canImport(Darwin)
                let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                #else
                let n = Glibc.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                #endif
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw SwitchError.blocked(L10n.tr("The write did not finish. The original file is preserved.")) }
                offset += n
            }
        }
        guard fsync(fd) == 0, renameat(dir, name, dir, url.lastPathComponent) == 0 else {
            throw SwitchError.blocked(L10n.tr("The atomic write failed. Original or recovery data is preserved."))
        }
        installed = true
        guard fsync(dir) == 0 else { throw SwitchError.blocked(L10n.tr("Could not persist the directory. Check the disk.")) }
    }
    public static func syncDirectory(_ url: URL) throws {
        try validateAncestors(url)
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SwitchError.unsafePath }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw SwitchError.blocked(L10n.tr("Could not persist the directory. Recovery data is preserved.")) }
    }
}
