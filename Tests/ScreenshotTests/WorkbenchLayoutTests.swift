import AppKit
import SwiftUI
import XCTest
@testable import ClaudeSwitch
import SwitchCore

@MainActor
final class WorkbenchLayoutTests: XCTestCase {
    // AppKit retains bridged toolbar items until the end of the test process.
    private static var windows: [NSWindow] = []

    func testUsageNavigationPreservesWindowWidth() async throws {
        _ = NSApplication.shared
        let state = AppState(demo: true)
        let controller = NSHostingController(rootView: MainWindow().environment(state))
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentRect: NSRect(x: -6000, y: 200, width: 1080, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = controller
        window.toolbarStyle = .unified
        window.orderFrontRegardless()
        Self.windows.append(window)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(500))

        for width: CGFloat in [920, 1080, 1400] {
            state.page = .accounts
            try await Task.sleep(for: .milliseconds(300))
            window.setContentSize(NSSize(width: width, height: 740))
            try await Task.sleep(for: .milliseconds(300))
            let expected = window.frame.width
            XCTAssertEqual(expected, width, accuracy: 1)
            for page: NavigationPage in [.usage, .accounts, .conversations, .usage] {
                state.page = page
                try await Task.sleep(for: .milliseconds(500))
                XCTAssertEqual(window.frame.width, expected, accuracy: 1,
                               "Navigating to \(page) must preserve the user's \(width)-point window width")
            }
        }
    }
}
