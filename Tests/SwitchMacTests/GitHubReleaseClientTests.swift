import XCTest
import SwitchCore
@testable import SwitchMac

final class GitHubReleaseClientTests: XCTestCase {
    private let endpoint = URL(string: "https://github.com/uiuing/claude-desktop-switch/releases/latest")!
    private func response(_ location: String?, status: Int = 302) -> HTTPURLResponse {
        HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: nil,
                        headerFields: location.map { ["Location": $0] } ?? [:])!
    }
    func testStableReleaseVersionsCompareNumerically() throws {
        let latest = try GitHubReleaseClient.parse(response("/uiuing/claude-desktop-switch/releases/tag/v0.1.10"), endpoint: endpoint)
        XCTAssertTrue(latest > ReleaseVersion("0.1.9")!)
        XCTAssertTrue(ReleaseVersion("1.0.0")! > ReleaseVersion("0.99.99")!)
        XCTAssertEqual(ReleaseVersion("v0.1.5"), ReleaseVersion("0.1.5"))
    }
    func testLatestRedirectMustStayOnThisProjectsStableReleasePage() throws {
        let target = "https://github.com/uiuing/claude-desktop-switch/releases/tag/"
        XCTAssertEqual(try GitHubReleaseClient.parse(response(target + "v0.1.5"), endpoint: endpoint), ReleaseVersion("0.1.5"))
        for location in ["https://github.com/fixture/other/releases/tag/v0.1.5", "https://invalid.test/releases/tag/v0.1.5",
                         target.replacingOccurrences(of: "https:", with: "http:") + "v0.1.5", target + "v0.1.5?download=true",
                         target + "v0.1.5#fragment", target + "v0.1.5-beta.1", target + "latest", target + "1.2",
                         target + "01.2.3", target + String(repeating: "9", count: 2100)] {
            XCTAssertThrowsError(try GitHubReleaseClient.parse(response(location), endpoint: endpoint))
        }
        XCTAssertThrowsError(try GitHubReleaseClient.parse(response(nil), endpoint: endpoint))
        XCTAssertThrowsError(try GitHubReleaseClient.parse(response(target + "v0.1.5", status: 200), endpoint: endpoint))
    }
    func testRateLimitHeadersCannotBeBypassedByAnEarlyRetry() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let response = try XCTUnwrap(HTTPURLResponse(url: endpoint, statusCode: 429,
            httpVersion: nil, headerFields: ["Retry-After": "7200", "X-RateLimit-Reset": "1800010800"]))
        XCTAssertEqual(GitHubReleaseClient.retryDate(response, now: now), now.addingTimeInterval(10800))
        let invalid = try XCTUnwrap(HTTPURLResponse(url: endpoint, statusCode: 403,
            httpVersion: nil, headerFields: ["Retry-After": "NaN", "X-RateLimit-Reset": "-10"]))
        XCTAssertEqual(GitHubReleaseClient.retryDate(invalid, now: now), now.addingTimeInterval(3600))
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let dateHeader = HTTPURLResponse(url: endpoint, statusCode: 429, httpVersion: nil,
            headerFields: ["Retry-After": formatter.string(from: now.addingTimeInterval(14400))])!
        XCTAssertEqual(GitHubReleaseClient.retryDate(dateHeader, now: now), now.addingTimeInterval(14400))
    }
}
