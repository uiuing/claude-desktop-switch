import Foundation
import SwitchCore

public struct ReleaseCheckError: Error {
    public var retryAfter: Date?
    public init(retryAfter: Date? = nil) { self.retryAfter = retryAfter }
}

public struct GitHubReleaseClient {
    public let endpoint: URL
    public init(endpoint: URL) { self.endpoint = endpoint }
    public func fetch() async throws -> ReleaseVersion {
        guard endpoint.scheme == "https", endpoint.host == "github.com", endpoint.user == nil,
              endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
              endpoint.path.hasSuffix("/releases/latest") else { throw ReleaseCheckError() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.urlCache = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: NoReleaseRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "HEAD"
        request.setValue("ClaudeSwitch-UpdateCheck", forHTTPHeaderField: "User-Agent")
        // Read only the public latest-release redirect. Do not follow it or download a release body.
        let (_, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.url == endpoint else { throw ReleaseCheckError() }
        return try Self.parse(response, endpoint: endpoint)
    }
    public static func parse(_ response: HTTPURLResponse, endpoint: URL) throws -> ReleaseVersion {
        guard [301, 302, 303, 307, 308].contains(response.statusCode) else {
            throw ReleaseCheckError(retryAfter: retryDate(response, now: Date()))
        }
        guard endpoint.scheme == "https", endpoint.host == "github.com", endpoint.path.hasSuffix("/releases/latest"),
              let location = response.value(forHTTPHeaderField: "Location"), location.count <= 2048,
              let target = URL(string: location, relativeTo: endpoint)?.absoluteURL,
              target.scheme == "https", target.host == endpoint.host, target.port == nil || target.port == 443,
              target.user == nil, target.password == nil, target.query == nil, target.fragment == nil else { throw ReleaseCheckError() }
        let prefix = String(endpoint.path.dropLast("/releases/latest".count)) + "/releases/tag/"
        guard target.path.hasPrefix(prefix), let version = ReleaseVersion(String(target.path.dropFirst(prefix.count))) else {
            throw ReleaseCheckError()
        }
        return version
    }
    public static func retryDate(_ response: HTTPURLResponse, now: Date) -> Date? {
        guard response.statusCode == 403 || response.statusCode == 429 else { return nil }
        var dates = [now.addingTimeInterval(3600)]
        if let value = response.value(forHTTPHeaderField: "Retry-After"), value.count <= 128 {
            if let seconds = Double(value), seconds.isFinite, seconds >= 0 { dates.append(now.addingTimeInterval(seconds)) }
            else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                if let date = formatter.date(from: value) { dates.append(date) }
            }
        }
        if let value = response.value(forHTTPHeaderField: "X-RateLimit-Reset"), let seconds = Double(value), seconds.isFinite {
            dates.append(Date(timeIntervalSince1970: seconds))
        }
        return dates.max()
    }
}

private final class NoReleaseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
