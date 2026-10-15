import XCTest
import SwitchCore
@testable import ClaudeSwitch

@MainActor
final class CodeTaskDemoTests: XCTestCase {
    func testDemoClickSwitchAndToggleStayLocal() async throws {
        let state = AppState(demo: true)
        XCTAssertNil(state.codeTaskPolling)
        let original = state.codeTasks
        let task = try XCTUnwrap(original.tasks.first)
        XCTAssertTrue(state.canOpenCodeTask(task))
        await state.refreshCodeTasks()
        XCTAssertEqual(state.codeTasks, original)
        await state.openCodeTask(task)
        XCTAssertEqual(state.message, L10n.tr("Demo: this conversation would open in Claude. No app was opened."))
        XCTAssertNil(state.codeTaskPolling)
        state.setCodeTasksEnabled(false)
        XCTAssertFalse(state.canOpenCodeTask(task)); XCTAssertTrue(state.codeTasks.tasks.isEmpty)
        state.setCodeTasksEnabled(true)
        XCTAssertEqual(state.codeTasks.tasks.count, original.tasks.count)
        state.working = true
        XCTAssertEqual(state.codeTasks.availability, .switching); XCTAssertNil(state.codeTasks.running)
        XCTAssertFalse(state.canOpenCodeTask(task))
        state.inventory?.activeAccountID = state.library.accounts[1].id
        state.working = false
        XCTAssertTrue(state.codeTasks.tasks.isEmpty)
        state.installDemoCodeTasks()
        XCTAssertFalse(state.canOpenCodeTask(task))
        XCTAssertTrue(state.codeTasks.tasks.allSatisfy { $0.conversation.accountID == state.activeID })
    }
}
