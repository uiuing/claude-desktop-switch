import Foundation

/// Published stable versions only. Unknown tags never become update prompts.
public struct ReleaseVersion: Comparable, Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public var description: String { "\(major).\(minor).\(patch)" }
    public init?(_ tag: String) {
        guard tag.count <= 64 else { return nil }
        let value = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ part in
            !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) } && (part.count == 1 || part.first != "0")
        }), let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        self.major = major; self.minor = minor; self.patch = patch
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
