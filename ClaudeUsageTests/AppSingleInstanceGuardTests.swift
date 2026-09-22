import XCTest
@testable import ClaudeUsage

final class AppSingleInstanceGuardTests: XCTestCase {
    func testOnlyOneGuardCanHoldChannelLock() throws {
        let directory =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClaudeUsage-instance-test-\(UUID().uuidString)",
                    isDirectory: true
                )
        defer {
            try? FileManager.default.removeItem(
                at: directory
            )
        }

        let first = AppSingleInstanceGuard()
        let second = AppSingleInstanceGuard()

        XCTAssertEqual(
            first.acquire(
                applicationSupportDirectoryURL:
                    directory
            ),
            .acquired
        )
        XCTAssertEqual(
            second.acquire(
                applicationSupportDirectoryURL:
                    directory
            ),
            .alreadyRunning
        )
        let lockAttributes =
            try FileManager.default.attributesOfItem(
                atPath:
                    directory.appendingPathComponent(
                        AppSingleInstanceGuard.lockFileName
                    ).path
            )
        let permissions =
            try XCTUnwrap(
                lockAttributes[
                    .posixPermissions
                ] as? NSNumber
            )
        XCTAssertEqual(
            permissions.intValue & 0o777,
            0o600
        )

        first.release()

        XCTAssertEqual(
            second.acquire(
                applicationSupportDirectoryURL:
                    directory
            ),
            .acquired
        )
        second.release()
    }

    func testDifferentChannelDirectoriesCanEachHoldOneLock() {
        let root =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClaudeUsage-channel-instance-test-\(UUID().uuidString)",
                    isDirectory: true
                )
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let production = AppSingleInstanceGuard()
        let staging = AppSingleInstanceGuard()

        XCTAssertEqual(
            production.acquire(
                applicationSupportDirectoryURL:
                    root.appendingPathComponent(
                        "ClaudeUsage",
                        isDirectory: true
                    )
            ),
            .acquired
        )
        XCTAssertEqual(
            staging.acquire(
                applicationSupportDirectoryURL:
                    root.appendingPathComponent(
                        "ClaudeUsage-stg",
                        isDirectory: true
                    )
            ),
            .acquired
        )
    }

    func testRelocationRetryWaitsUntilPredecessorReleasesLock() {
        var attempts = 0
        var waits = 0
        var clock: TimeInterval = 0

        let result = AppRelaunchHandoffPolicy.acquire(
            timeout: 10,
            pollInterval: 1,
            elapsed: { clock },
            wait: { interval in
                waits += 1
                clock += interval
            },
            attempt: {
                attempts += 1
                return attempts < 3
                    ? .alreadyRunning
                    : .acquired
            }
        )

        XCTAssertEqual(result, .acquired)
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(waits, 2)
    }

    func testRelocationRetryStopsOnFailureWithoutWaiting() {
        var waits = 0
        var clock: TimeInterval = 0

        let result = AppRelaunchHandoffPolicy.acquire(
            timeout: 3,
            pollInterval: 1,
            elapsed: { clock },
            wait: { interval in
                waits += 1
                clock += interval
            },
            attempt: { .failed(13) }
        )

        XCTAssertEqual(result, .failed(13))
        XCTAssertEqual(waits, 0)
    }

    func testRelocationRetryGivesUpAtTimeout() {
        var attempts = 0
        var clock: TimeInterval = 0

        let result = AppRelaunchHandoffPolicy.acquire(
            timeout: 3,
            pollInterval: 1,
            elapsed: { clock },
            wait: { clock += $0 },
            attempt: {
                attempts += 1
                return .alreadyRunning
            }
        )

        XCTAssertEqual(result, .alreadyRunning)
        XCTAssertEqual(attempts, 4)
    }

    /// 두 상수는 한 쌍이다. 대기가 선행 프로세스의 정리 상한보다 짧아지면
    /// 이동 직후 양쪽 프로세스가 모두 사라진다.
    func testSuccessorWaitOutlastsPredecessorShutdown() {
        XCTAssertGreaterThan(
            AppRelaunchHandoffPolicy
                .relaunchAfterMoveTimeout,
            AppRelaunchHandoffPolicy
                .ownedRuntimeShutdownTimeout
        )
    }

    func testPredecessorLivenessRejectsUnusableProcesses() {
        XCTAssertFalse(
            AppRelaunchHandoffPolicy
                .predecessorIsRunning(0)
        )
        XCTAssertFalse(
            AppRelaunchHandoffPolicy
                .predecessorIsRunning(-1)
        )
        XCTAssertTrue(
            AppRelaunchHandoffPolicy
                .predecessorIsRunning(
                    ProcessInfo.processInfo
                        .processIdentifier
                )
        )
    }

    /// 순수 정책이 아니라 실제 시계·대기·잠금에 연결된 배선을 고정한다.
    func testRelocationWaitUsesItsTimeoutAgainstAHeldLock() throws {
        let directory =
            FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ClaudeUsage-relocation-test-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(
                at: directory
            )
        }

        let holder = AppSingleInstanceGuard()
        XCTAssertEqual(
            holder.acquire(
                applicationSupportDirectoryURL: directory
            ),
            .acquired
        )

        let waiter = AppSingleInstanceGuard()
        let startedAt =
            ProcessInfo.processInfo.systemUptime
        let result =
            waiter
            .acquireWaitingForRelocatedPredecessor(
                applicationSupportDirectoryURL:
                    directory,
                timeout: 0.3
            )
        let waited =
            ProcessInfo.processInfo.systemUptime
            - startedAt

        XCTAssertEqual(result, .alreadyRunning)
        XCTAssertGreaterThanOrEqual(waited, 0.3)
        XCTAssertLessThan(waited, 5)
    }

    /// 이번 수정이 막으려는 상황 자체를 고정한다. 선행 프로세스가 종료 절차를
    /// 끝내고 잠금을 놓는 순간 후속 프로세스가 이어받아야 한다.
    func testRelocationWaitTakesOverOncePredecessorReleases() throws {
        let directory =
            FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ClaudeUsage-handoff-test-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(
                at: directory
            )
        }

        let predecessor = AppSingleInstanceGuard()
        XCTAssertEqual(
            predecessor.acquire(
                applicationSupportDirectoryURL: directory
            ),
            .acquired
        )

        DispatchQueue.global().asyncAfter(
            deadline: .now() + 0.3
        ) {
            predecessor.release()
        }

        let successor = AppSingleInstanceGuard()
        let startedAt =
            ProcessInfo.processInfo.systemUptime
        let result =
            successor
            .acquireWaitingForRelocatedPredecessor(
                applicationSupportDirectoryURL:
                    directory,
                timeout: 5
            )
        let waited =
            ProcessInfo.processInfo.systemUptime
            - startedAt

        XCTAssertEqual(result, .acquired)
        XCTAssertGreaterThanOrEqual(waited, 0.3)
        XCTAssertLessThan(waited, 5)
    }
}
