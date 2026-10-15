import Foundation

/// Only an explicit Add account flow creates this intent. Saving unrelated logins does not transfer sessions.
public struct NewAccountFollowUp: Codable, Equatable, Sendable {
    public var id = UUID()
    public var sourceAccountID: String?
    public var targetAccountID: String?
    public var reviewOffered = false
    public init(sourceAccountID: String?) { self.sourceAccountID = sourceAccountID }
}
