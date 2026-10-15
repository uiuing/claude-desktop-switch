import AppKit
import SwiftUI
import XCTest
import SwitchCore
@testable import ClaudeSwitch

@MainActor
final class MenuBarStatusImageTests: XCTestCase {
    private var icon: NSImage { NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)! }
    private var ready: CodeTaskSnapshot {
        .init(availability: .ready, tasks: (0..<5).map { index in
            CodeTask(conversation: .init(id: "fixture-\(index)", sessionID: "local_0a1b2c3d-1111-4aaa-8bbb-000000000001",
                accountID: "0a1b2c3d-1111-4aaa-8bbb-000000000002", organizationID: "0a1b2c3d-1111-4aaa-8bbb-000000000003",
                title: "Fixture", kind: .code, modifiedAt: .distantPast, recordRelativePath: "fixture"),
                status: index < 3 ? .running : .permission)
        })
    }
    func testNativeImageContainsQuotaAndBothTaskCounts() {
        for scheme in [ColorScheme.light, .dark] {
            let quota = MenuBarStatusImage.image(quota: "85%", reminder: nil, tasks: nil, icon: icon, colorScheme: scheme)
            let full = MenuBarStatusImage.image(quota: "85%", reminder: nil, tasks: ready, icon: icon, colorScheme: scheme)
            XCTAssertGreaterThan(full.size.width, quota.size.width + 40)
            XCTAssertLessThan(full.size.height, 25)
            XCTAssertFalse(full.isTemplate)
            let description = MenuBarStatusImage.description(quota: "85%", reminder: nil, tasks: ready)
            XCTAssertTrue(description.contains("85%")); XCTAssertTrue(description.contains(ready.detail))
        }
    }
    func testUnavailableStatesReserveNoSpaceAndHaveNoPlaceholder() {
        let quota = MenuBarStatusImage.image(quota: "85%", reminder: nil, tasks: nil, icon: icon, colorScheme: .light)
        let description = MenuBarStatusImage.description(quota: "85%", reminder: nil, tasks: nil)
        for availability: CodeTaskSnapshot.Availability in [.incomplete, .connecting, .switching, .offline, .unavailable] {
            let tasks = CodeTaskSnapshot(availability: availability)
            let image = MenuBarStatusImage.image(quota: "85%", reminder: nil, tasks: tasks, icon: icon, colorScheme: .light)
            XCTAssertEqual(image.size, quota.size)
            XCTAssertEqual(MenuBarStatusImage.description(quota: "85%", reminder: nil, tasks: tasks), description)
        }
    }
    func testConfirmedZeroStillHasATaskIndicator() {
        let quota = MenuBarStatusImage.image(quota: "85%", reminder: nil, tasks: nil, icon: icon, colorScheme: .light)
        let zero = MenuBarStatusImage.image(quota: "85%", reminder: nil, tasks: .init(availability: .ready), icon: icon, colorScheme: .light)
        XCTAssertGreaterThan(zero.size.width, quota.size.width)
    }
}
