import XCTest
@testable import ClaudeUsage

/// `ClaudeAccountStoreNotificationObserver` 는 ClaudeAccountStore 변경이
/// ClaudeAPIService 의 in-memory 캐시로 자동 전파되는 다리 역할이다.
/// 이 다리가 끊기면 "조직을 바꿔도 새로고침이 이전 조직 사용량을 보여주는"
/// 회귀가 발생하므로 단위 테스트로 고정한다.
final class ClaudeAccountStoreNotificationObserverTests: XCTestCase {
    func testHandlerIsCalledWhenAccountsDidChangeNotificationIsPosted() {
        let observer = ClaudeAccountStoreNotificationObserver()
        let expectation = expectation(description: "handler fired")
        expectation.expectedFulfillmentCount = 1

        observer.start {
            expectation.fulfill()
        }

        NotificationCenter.default.post(name: .claudeAccountsDidChange, object: nil)

        wait(for: [expectation], timeout: 1.0)
        observer.stop()
    }

    func testStartReplacesPreviousHandler() {
        let observer = ClaudeAccountStoreNotificationObserver()
        let oldHandlerExpectation = expectation(description: "old handler should not fire")
        oldHandlerExpectation.isInverted = true
        let newHandlerExpectation = expectation(description: "new handler fired")

        observer.start {
            oldHandlerExpectation.fulfill()
        }
        observer.start {
            newHandlerExpectation.fulfill()
        }

        NotificationCenter.default.post(name: .claudeAccountsDidChange, object: nil)

        wait(for: [newHandlerExpectation, oldHandlerExpectation], timeout: 0.5)
        observer.stop()
    }

    func testStopPreventsFurtherCallbacks() {
        let observer = ClaudeAccountStoreNotificationObserver()
        let shouldNotFire = expectation(description: "handler must not fire after stop")
        shouldNotFire.isInverted = true

        observer.start {
            shouldNotFire.fulfill()
        }
        observer.stop()

        NotificationCenter.default.post(name: .claudeAccountsDidChange, object: nil)

        wait(for: [shouldNotFire], timeout: 0.5)
    }
}
