import AppKit
import XCTest
@testable import ClaudeSwitch

@MainActor
final class MenuPanelDismissalTests: XCTestCase {
    @MainActor private final class NativeToggle: NSObject {
        let panel: NSWindow
        var presented = false
        var calls = 0
        init(panel: NSWindow) { self.panel = panel }
        @objc func toggle(_ button: NSStatusBarButton) {
            calls += 1; presented.toggle()
            button.state = presented ? .on : .off
            if presented { panel.orderFrontRegardless() }
            else { panel.orderOut(nil) }
        }
    }
    private func panel() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -6000, y: 100, width: 200, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in window.close() }
        return window
    }
    private func statusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: 0)
        addTeardownBlock { @MainActor in NSStatusBar.system.removeStatusItem(item) }
        return item
    }
    func testNativeToggleClearsSelectionAndNextClickReopens() throws {
        let window = panel(), item = statusItem(), button = try XCTUnwrap(item.button)
        let native = NativeToggle(panel: window)
        button.target = native; button.action = #selector(NativeToggle.toggle(_:))
        let buttonWindow = try XCTUnwrap(button.window)
        for _ in 0..<3 {
            button.performClick(nil)
            XCTAssertTrue(window.isVisible); XCTAssertTrue(native.presented); XCTAssertEqual(button.state, .on)
            MenuPanelDismissal.close(window, in: [buttonWindow, window])
            XCTAssertFalse(window.isVisible); XCTAssertFalse(native.presented); XCTAssertEqual(button.state, .off)
        }
        XCTAssertEqual(native.calls, 6)
    }
    func testHiddenPanelAndNilPanelDoNotToggleMenuOpen() throws {
        let window = panel(), item = statusItem(), button = try XCTUnwrap(item.button)
        let native = NativeToggle(panel: window)
        button.target = native; button.action = #selector(NativeToggle.toggle(_:))
        let buttonWindow = try XCTUnwrap(button.window)
        MenuPanelDismissal.close(window, in: [buttonWindow])
        MenuPanelDismissal.close(nil, in: [buttonWindow])
        XCTAssertEqual(native.calls, 0); XCTAssertFalse(native.presented)
    }
    func testPlainPreviewWindowCanCloseWithoutAStatusItem() {
        let window = panel()
        window.orderFrontRegardless()
        MenuPanelDismissal.close(window, in: [window])
        XCTAssertFalse(window.isVisible)
    }
    func testAmbiguousStatusItemsAreNeverClicked() throws {
        let window = panel(), first = statusItem(), second = statusItem()
        let native = NativeToggle(panel: window)
        for item in [first, second] {
            item.button?.target = native; item.button?.action = #selector(NativeToggle.toggle(_:))
        }
        window.orderFrontRegardless()
        let windows = try [XCTUnwrap(first.button?.window), XCTUnwrap(second.button?.window)]
        MenuPanelDismissal.close(window, in: windows)
        XCTAssertEqual(native.calls, 0); XCTAssertFalse(window.isVisible)
    }
}
