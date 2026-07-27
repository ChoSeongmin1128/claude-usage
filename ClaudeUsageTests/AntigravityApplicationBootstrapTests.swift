import XCTest
@testable import ClaudeUsage

final class AntigravityApplicationBootstrapTests:
    XCTestCase
{
    func testBootstrapGateRunsOperationExactlyOnce() {
        let gate = AntigravitySettingsBootstrapGate<Int>()
        var invocationCount = 0

        let first = gate.run {
            invocationCount += 1
            return 7
        }
        let second = gate.run {
            invocationCount += 1
            return 9
        }

        XCTAssertEqual(first, 7)
        XCTAssertEqual(second, 7)
        XCTAssertEqual(invocationCount, 1)
    }

    func testConcurrentBootstrapCallersShareCompletedResult()
        async
    {
        let gate = AntigravitySettingsBootstrapGate<Int>()
        let counter = LockedBootstrapCounter()

        let values = await withTaskGroup(
            of: Int.self,
            returning: [Int].self
        ) { group in
            for _ in 0 ..< 32 {
                group.addTask {
                    gate.run {
                        counter.increment()
                        Thread.sleep(
                            forTimeInterval: 0.002
                        )
                        return 42
                    }
                }
            }

            var values: [Int] = []
            for await value in group {
                values.append(value)
            }
            return values
        }

        XCTAssertEqual(values.count, 32)
        XCTAssertTrue(values.allSatisfy { $0 == 42 })
        XCTAssertEqual(counter.value, 1)
    }
}

private final class LockedBootstrapCounter:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock {
            storage += 1
        }
    }
}
