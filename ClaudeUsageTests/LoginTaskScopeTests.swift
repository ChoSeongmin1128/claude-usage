import XCTest
@testable import ClaudeUsage

@MainActor
final class LoginTaskScopeTests: XCTestCase {
    func testClosingLoginDiscardsACompletionThatIgnoresCancellation() async {
        let scope = LoginTaskScope()
        let started = expectation(description: "started")
        let finished = expectation(description: "operation finished")
        var continuation: CheckedContinuation<Void, Never>?
        var applied = false
        scope.run {
            await withCheckedContinuation {
                continuation = $0; started.fulfill()
            }
            finished.fulfill()
            return "old login"
        } apply: { _ in
            applied = true
        }
        await fulfillment(of: [started], timeout: 1)
        scope.cancel()
        continuation?.resume()
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertFalse(applied)
    }

    func testChangingLoginMethodCannotBeOverwrittenByThePreviousMethod() async {
        let scope = LoginTaskScope()
        let started = expectation(description: "first started")
        let oldFinished = expectation(description: "first operation finished")
        let newApplied = expectation(description: "second applied")
        var continuation: CheckedContinuation<Void, Never>?
        var results: [String] = []
        scope.run {
            await withCheckedContinuation {
                continuation = $0; started.fulfill()
            }
            oldFinished.fulfill()
            return "Chrome"
        } apply: {
            results.append($0)
        }
        await fulfillment(of: [started], timeout: 1)
        scope.run {
            "CLI"
        } apply: {
            results.append($0); newApplied.fulfill()
        }
        await fulfillment(of: [newApplied], timeout: 1)
        continuation?.resume()
        await fulfillment(of: [oldFinished], timeout: 1)
        XCTAssertEqual(results, ["CLI"])
    }
}
