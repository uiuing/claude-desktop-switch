import Foundation
import SwitchCore

public struct UsageNotReady: LocalizedError {
    public enum Reason { case updating, expired, expiring }
    public let reason: Reason
    public let message: String
    public init(reason: Reason) {
        self.reason = reason
        switch reason {
        case .updating: message = L10n.tr("Waiting for Claude to publish its login credentials.")
        case .expired: message = L10n.tr("The access token has expired. Waiting for Claude to update it.")
        case .expiring: message = L10n.tr("The access token expires shortly. Waiting for Claude to update it.")
        }
    }
    public init(message: String) { reason = .updating; self.message = message }
    public var errorDescription: String? { message }
}
public struct UsageUnchanged: Error {}
public struct UsageCoolingDown: LocalizedError {
    public let until: Date
    public var errorDescription: String? {
        L10n.tr("Quota retry is paused. Try again in {0} seconds.",
                max(1, ceil(until.timeIntervalSinceNow)).formatted(.number.precision(.fractionLength(0)).locale(L10n.locale)))
    }
}
public enum UsageFailure: String, LocalizedError {
    case unauthorized, forbidden, missingScopes, invalidCredentials, ambiguousCredentials, identityMismatch, offline, server, invalidResponse, keychain
    public var waitsForCredentials: Bool { self == .unauthorized }
    public var isTransient: Bool { self == .offline || self == .server }
    public var errorDescription: String? {
        switch self {
        case .unauthorized: return L10n.tr("This access token was rejected. Waiting for Claude to update its credentials.")
        case .forbidden: return L10n.tr("Quota access was denied. Check this account's access in Claude.")
        case .missingScopes: return L10n.tr("No supported quota credential was found. Open Claude's Code tab to check the login.")
        case .invalidCredentials: return L10n.tr("The credential expiry or format is unsupported. The login has not been marked expired.")
        case .ambiguousCredentials: return L10n.tr("Several quota credentials match. The request was stopped because their ownership is ambiguous.")
        case .identityMismatch: return L10n.tr("The online identity does not match the selected login. Quota lookup was stopped.")
        case .offline: return L10n.tr("The quota service could not be reached. The last reading is retained.")
        case .server: return L10n.tr("The quota service is temporarily unavailable. The last reading is retained.")
        case .invalidResponse: return L10n.tr("The quota format has changed. The last reading is retained.")
        case .keychain: return L10n.tr("Allow Keychain access to update quota.")
        }
    }
}

/// OAuth compatibility baseline checked against Desktop 2.37337.1. URLSession is not Electron's session.
enum DesktopUsageProtocol {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let origin = "https://api.anthropic.com"
    static func request(path: String, token: String, codeVersion: String) throws -> URLRequest {
        guard ["/api/oauth/profile", "/api/oauth/usage"].contains(path),
              var components = URLComponents(string: origin + path) else { throw UsageFailure.invalidResponse }
        if path == "/api/oauth/usage" {
            components.queryItems = [URLQueryItem(name: "skip_spend", value: "1")]
        }
        guard let url = components.url else { throw UsageFailure.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Preserve the established Code compatibility identity, without claiming a native Desktop request.
        request.setValue("claude-code/" + codeVersion, forHTTPHeaderField: "User-Agent")
        return request
    }
}
