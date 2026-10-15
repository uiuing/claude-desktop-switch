import XCTest
import Security
@testable import SwitchMac

final class KeychainInteractionTests: XCTestCase {
    func testSilentReadsDisableLegacyInteractionAndRestoreIt() {
        var enabled = true, queries = 0
        let interaction = KeychainInteraction(get: { (errSecSuccess, enabled) }, set: { enabled = $0; return errSecSuccess })
        let result = interaction.perform(allowPrompt: false) { allowed in
            XCTAssertFalse(allowed); XCTAssertFalse(enabled); queries += 1
            return .init(errSecInteractionNotAllowed)
        }
        XCTAssertEqual(result.status, errSecInteractionNotAllowed)
        XCTAssertEqual(queries, 1)
        XCTAssertTrue(enabled)
    }

    func testExplicitApprovalRetriesOnlyAnAuthorizationFailureOnce() {
        var enabled = false, requests: [Bool] = []
        let interaction = KeychainInteraction(get: { (errSecSuccess, enabled) }, set: { enabled = $0; return errSecSuccess })
        let result = interaction.perform(allowPrompt: true) { allowed in
            XCTAssertEqual(enabled, allowed); requests.append(allowed)
            return .init(allowed ? errSecUserCanceled : errSecInteractionNotAllowed)
        }
        XCTAssertEqual(requests, [false, true])
        XCTAssertEqual(result.status, errSecUserCanceled)
        XCTAssertFalse(enabled)
        for status in [errSecItemNotFound, errSecDecode, errSecUserCanceled] {
            requests.removeAll()
            _ = interaction.perform(allowPrompt: true) { allowed in requests.append(allowed); return .init(status) }
            XCTAssertEqual(requests, [false])
        }
    }

    func testAnAlreadyAllowedItemDoesNotRequestApprovalAgain() {
        let interaction = KeychainInteraction(get: { (errSecSuccess, true) }, set: { _ in errSecSuccess })
        var requests: [Bool] = []
        let result = interaction.perform(allowPrompt: true) { allowed in
            requests.append(allowed); return .init(errSecSuccess, data: Data("fixture".utf8))
        }
        XCTAssertEqual(requests, [false])
        XCTAssertEqual(result.status, errSecSuccess)
    }

    func testFailureToDisableInteractionDoesNotQueryTheKeychain() {
        let interaction = KeychainInteraction(get: { (errSecSuccess, true) }, set: { _ in errSecNotAvailable })
        let result = interaction.perform(allowPrompt: true) { _ in
            XCTFail("No query is safe without the interaction guard"); return .init(errSecSuccess)
        }
        XCTAssertEqual(result.status, errSecNotAvailable)
    }

    func testDifferentItemsCannotReadWhileAnotherItemHasAnInteractivePrompt() {
        let entered = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
        let first = expectation(description: "Explicit authorization"), second = expectation(description: "Silent vault access")
        var enabled = true
        let interaction = KeychainInteraction(get: { (errSecSuccess, enabled) }, set: { enabled = $0; return errSecSuccess })
        DispatchQueue.global().async {
            _ = interaction.perform(allowPrompt: true) { allowed in
                if !allowed { return .init(errSecInteractionNotAllowed) }
                entered.signal()
                guard finish.wait(timeout: .now() + 3) == .success else { return .init(errSecUserCanceled) }
                return .init(errSecSuccess)
            }
            first.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        DispatchQueue.global().async {
            _ = interaction.perform(allowPrompt: false) { allowed in
                XCTAssertFalse(allowed); XCTAssertFalse(enabled)
                return .init(errSecSuccess)
            }
            second.fulfill()
        }
        finish.signal()
        wait(for: [first, second], timeout: 4)
    }
}
