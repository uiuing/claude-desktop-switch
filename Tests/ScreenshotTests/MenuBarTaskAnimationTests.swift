import AppKit
import XCTest
import SwitchCore
@testable import ClaudeSwitch

@MainActor
final class MenuBarTaskAnimationTests: XCTestCase {
    func testAnimationAdvancesOnlyWhileRequestedAndStopsCleanly() async throws {
        let animation = MenuBarTaskAnimation(observeSystem: false, reduceMotion: { false })
        animation.setRunning(true)
        XCTAssertTrue(animation.isAnimating)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertGreaterThan(animation.frame, 0)
        animation.setRunning(false)
        XCTAssertFalse(animation.isAnimating); XCTAssertEqual(animation.frame, 0)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(animation.frame, 0)
    }
    func testReduceMotionAndDemoDisableTheTimer() {
        var reduced = true
        let animation = MenuBarTaskAnimation(observeSystem: false, reduceMotion: { reduced })
        animation.setRunning(true)
        XCTAssertFalse(animation.isAnimating)
        reduced = false; animation.reconcile()
        XCTAssertTrue(animation.isAnimating)
        reduced = true; animation.reconcile()
        XCTAssertFalse(animation.isAnimating); XCTAssertEqual(animation.frame, 0)
        let demo = MenuBarTaskAnimation(enabled: false, observeSystem: false, reduceMotion: { false })
        demo.setRunning(true)
        XCTAssertFalse(demo.isAnimating)
    }
    func testCachedFramesRotateOnlyTheRunningIndicator() throws {
        let data = DemoData.make(), scope = try XCTUnwrap(CodeTaskScope(accountID: data.library.accounts[0].id,
                                                       organizationID: data.library.accounts[0].organizationID!))
        let session = try XCTUnwrap(data.inventory.conversations.first(where: scope.contains))
        let running = CodeTaskSnapshot(scope: scope, availability: .ready, tasks: [.init(conversation: session, status: .running)])
        let waiting = CodeTaskSnapshot(scope: scope, availability: .ready, tasks: [.init(conversation: session, status: .permission)])
        let icon = try XCTUnwrap(NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil))
        let cache = MenuBarStatusImage.Cache()
        func image(_ tasks: CodeTaskSnapshot, frame: Int) -> NSImage {
            cache.image(quota: "85%", reminder: nil, tasks: tasks, icon: icon, colorScheme: .dark, frame: frame)
        }
        let first = image(running, frame: 0), next = image(running, frame: 1)
        XCTAssertEqual(first.size, next.size)
        XCTAssertNotEqual(first.tiffRepresentation, next.tiffRepresentation)
        XCTAssertTrue(first === image(running, frame: 0))
        XCTAssertTrue(first === image(running, frame: MenuBarTaskAnimation.frameCount))
        let still = image(waiting, frame: 0)
        XCTAssertTrue(still === image(waiting, frame: 1))
        let missing = CodeTaskSnapshot(scope: scope, availability: .incomplete)
        XCTAssertTrue(image(missing, frame: 0) === image(missing, frame: 7))
    }
}
