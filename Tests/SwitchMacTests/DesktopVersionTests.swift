import XCTest
@testable import SwitchMac

final class DesktopVersionTests: XCTestCase {
    func testLoginsFromTheSameOrAnOlderClaudeCanBeRestored() {
        XCTAssertTrue(DesktopVersion.canRestore(saved: "0.13.64", installed: "0.13.64"))
        XCTAssertTrue(DesktopVersion.canRestore(saved: "0.13.64", installed: "0.14.2"))
        XCTAssertTrue(DesktopVersion.canRestore(saved: "0.9.9", installed: "0.10.0"))
        XCTAssertTrue(DesktopVersion.canRestore(saved: "1.0", installed: "1.0.0"))
    }

    func testLoginsFromANewerClaudeAreRefused() {
        XCTAssertFalse(DesktopVersion.canRestore(saved: "0.14.2", installed: "0.13.64"))
        XCTAssertFalse(DesktopVersion.canRestore(saved: "0.10.0", installed: "0.9.9"))
    }

    func testVersionsThatCannotBeComparedMustMatch() {
        XCTAssertFalse(DesktopVersion.canRestore(saved: "0.14.0-beta", installed: "0.14.1"))
        XCTAssertFalse(DesktopVersion.canRestore(saved: "0.13", installed: ""))
        XCTAssertTrue(DesktopVersion.canRestore(saved: "0.14.0-beta", installed: "0.14.0-beta"))
    }
}
