import Darwin
import Foundation
import XCTest
@testable import ClaudeUsage

final class AntigravityManagedCLISessionTests:
    XCTestCase
{
    func testDisabledAuthorizationDoesNotTouchDependencies()
        async throws
    {
        let harness = ManagedSessionHarness()
        let session = harness.makeSession()

        do {
            _ = try await session.withRuntime(
                authorization: .disabled,
                executable: harness.executable,
                deadline: AntigravityRPCDeadline()
            ) { _ in true }
            XCTFail("Disabled managed launch unexpectedly ran")
        } catch let error as AntigravityManagedSessionError {
            XCTAssertEqual(error, .launchDisabled)
        }

        XCTAssertEqual(harness.launcher.launchCount, 0)
        XCTAssertEqual(harness.recovery.callCount, 0)
        XCTAssertEqual(harness.recordStore.saveCount, 0)
        XCTAssertEqual(harness.readiness.callCount, 0)
        XCTAssertEqual(harness.coordinator.callCount, 0)
    }

    func testExecutableReplacementAfterPreparationIsRejectedBeforeSpawn()
        async
    {
        let harness = ManagedSessionHarness()
        let revalidator =
            ManagedSessionScriptedExecutableRevalidator(
                results: [true, false]
            )
        let session = harness.makeSession(
            executableRevalidator: revalidator
        )

        do {
            _ = try await session.withRuntime(
                authorization: .automatic(
                    idleTimeout: .seconds(5)
                ),
                executable: harness.executable,
                deadline: AntigravityRPCDeadline()
            ) { _ in true }
            XCTFail("교체된 실행 파일이 시작되면 안 됩니다")
        } catch let error as AntigravityManagedSessionError {
            XCTAssertEqual(error, .executableNotAllowed)
        } catch {
            XCTFail("예상하지 못한 오류: \(error)")
        }

        XCTAssertEqual(harness.launcher.launchCount, 0)
        XCTAssertEqual(revalidator.callCount, 2)
    }

    func testConcurrentCallersShareOneProcessAndRuntime()
        async throws
    {
        let harness = ManagedSessionHarness()
        let session = harness.makeSession()

        let ports = try await withThrowingTaskGroup(
            of: UInt16.self
        ) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await session.withRuntime(
                        authorization: .automatic(
                            idleTimeout: .seconds(5)
                        ),
                        executable: harness.executable,
                        deadline: AntigravityRPCDeadline()
                    ) { runtime in
                        runtime.endpoint.port.rawValue
                    }
                }
            }

            var results: [UInt16] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }

        XCTAssertEqual(ports.count, 20)
        XCTAssertEqual(Set(ports), Set([UInt16(45_321)]))
        XCTAssertEqual(harness.launcher.launchCount, 1)
        XCTAssertEqual(harness.recovery.callCount, 1)
        XCTAssertEqual(harness.recordStore.saveCount, 1)
        XCTAssertEqual(harness.readiness.callCount, 1)
        XCTAssertEqual(harness.handle.terminationCount, 0)

        await session.shutdown()
        XCTAssertEqual(harness.handle.terminationCount, 1)
    }

    func testCancelledWaiterDoesNotCancelSharedLaunch()
        async throws
    {
        let readinessGate = ManagedSessionGate()
        let harness = ManagedSessionHarness(
            readinessGate: readinessGate
        )
        let session = harness.makeSession()

        let retained = Task {
            try await session.withRuntime(
                authorization: .automatic(
                    idleTimeout: .seconds(5)
                ),
                executable: harness.executable,
                deadline: AntigravityRPCDeadline()
            ) { _ in "retained" }
        }
        await readinessGate.waitUntilWaiterArrives()

        let cancelled = Task {
            try await session.withRuntime(
                authorization: .automatic(
                    idleTimeout: .seconds(5)
                ),
                executable: harness.executable,
                deadline: AntigravityRPCDeadline()
            ) { _ in "cancelled" }
        }
        await Task.yield()
        cancelled.cancel()

        do {
            _ = try await cancelled.value
            XCTFail("Cancelled waiter unexpectedly completed")
        } catch let error as AntigravityManagedSessionError {
            XCTAssertEqual(error, .cancelled)
        }

        XCTAssertEqual(harness.launcher.launchCount, 1)
        XCTAssertEqual(harness.handle.terminationCount, 0)

        await readinessGate.release()
        let retainedValue = try await retained.value
        XCTAssertEqual(retainedValue, "retained")
        XCTAssertEqual(harness.handle.terminationCount, 0)

        await session.shutdown()
        XCTAssertEqual(harness.handle.terminationCount, 1)
    }

    func testShortDeadlineWaiterLeavesSharedLaunchRunning()
        async throws
    {
        let readinessGate = ManagedSessionGate()
        let harness = ManagedSessionHarness(
            readinessGate: readinessGate
        )
        let session = harness.makeSession()

        let retained = Task {
            try await session.withRuntime(
                authorization: .automatic(
                    idleTimeout: .seconds(5)
                ),
                executable: harness.executable,
                deadline: AntigravityRPCDeadline()
            ) { _ in "retained" }
        }
        await readinessGate.waitUntilWaiterArrives()

        let shortDeadline = Task {
            try await session.withRuntime(
                authorization: .automatic(
                    idleTimeout: .seconds(5)
                ),
                executable: harness.executable,
                deadline: AntigravityRPCDeadline(
                    totalTimeout: .milliseconds(40),
                    discoveryTimeout: .milliseconds(40)
                )
            ) { _ in "short" }
        }

        do {
            _ = try await shortDeadline.value
            XCTFail("호출자 deadline을 넘긴 waiter가 성공하면 안 됩니다")
        } catch let error as AntigravityManagedSessionError {
            XCTAssertEqual(error, .readinessTimedOut)
        }

        XCTAssertEqual(harness.launcher.launchCount, 1)
        XCTAssertEqual(harness.handle.terminationCount, 0)

        await readinessGate.release()
        let retainedValue = try await retained.value
        XCTAssertEqual(retainedValue, "retained")
        await session.shutdown()
        XCTAssertEqual(harness.handle.terminationCount, 1)
    }

    func testCancellingOnlyWaiterCancelsAndCleansOwnedProcess()
        async throws
    {
        let harness = ManagedSessionHarness(
            readinessDelay: .seconds(60)
        )
        let session = harness.makeSession()
        let operation = Task {
            try await session.withRuntime(
                authorization: .automatic(
                    idleTimeout: .seconds(5)
                ),
                executable: harness.executable,
                deadline: AntigravityRPCDeadline()
            ) { _ in true }
        }

        try await waitUntil {
            harness.readiness.callCount == 1
        }
        operation.cancel()

        do {
            _ = try await operation.value
            XCTFail("취소된 유일 waiter가 성공하면 안 됩니다")
        } catch let error as AntigravityManagedSessionError {
            XCTAssertEqual(error, .cancelled)
        }

        try await waitUntil {
            harness.handle.terminationCount == 1
        }
        XCTAssertEqual(
            harness.processTreeTerminator.terminationCount,
            1,
            "Cancelled caller must not prevent durable tree cleanup"
        )
        XCTAssertEqual(harness.registry.registerCount, 1)
        XCTAssertEqual(harness.registry.unregisterCount, 1)
        await session.shutdown()
        XCTAssertEqual(harness.handle.terminationCount, 1)
    }

    func testCancelledAndExpiredRequestsDoNotWaitForBlockedCleanupOrRelaunch()
        async throws
    {
        let terminationGate = ManagedSessionGate()
        let harness = ManagedSessionHarness(
            terminationGate: terminationGate
        )
        let session = harness.makeSession()

        _ = try await session.withRuntime(
            authorization: .automatic(idleTimeout: .seconds(5)),
            executable: harness.executable,
            deadline: AntigravityRPCDeadline()
        ) { _ in true }
        let resetTask = Task {
            await session.reset(reason: .userRequested)
        }
        await terminationGate.waitUntilWaiterArrives()

        let cancelled = Task {
            try await session.withRuntime(
                authorization: .automatic(
                    idleTimeout: .seconds(5)
                ),
                executable: harness.executable,
                deadline: AntigravityRPCDeadline()
            ) { _ in true }
        }
        await Task.yield()
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled cleanup waiter unexpectedly launched")
        } catch let error as AntigravityManagedSessionError {
            XCTAssertEqual(error, .cancelled)
        }

        do {
            _ = try await session.withRuntime(
                authorization: .automatic(
                    idleTimeout: .seconds(5)
                ),
                executable: harness.executable,
                deadline: AntigravityRPCDeadline(
                    totalTimeout: .milliseconds(30),
                    discoveryTimeout: .milliseconds(30)
                )
            ) { _ in true }
            XCTFail("Expired cleanup waiter unexpectedly launched")
        } catch let error as AntigravityManagedSessionError {
            XCTAssertEqual(error, .readinessTimedOut)
        }

        XCTAssertEqual(
            harness.launcher.launchCount,
            1,
            "Requests abandoned at the cleanup barrier must not spawn"
        )
        await terminationGate.release()
        await resetTask.value
    }

    func testPreCancelledRequestCannotLeaseRunningRuntime()
        async throws
    {
        let harness = ManagedSessionHarness()
        let session = harness.makeSession()
        _ = try await session.withRuntime(
            authorization: .automatic(idleTimeout: .seconds(5)),
            executable: harness.executable,
            deadline: AntigravityRPCDeadline()
        ) { _ in true }

        let startGate = ManagedSessionGate()
        let operationRecorder =
            ManagedSessionOperationRecorder()
        let operation = Task {
            await startGate.wait()
            return try await session.withRuntime(
                authorization: .automatic(
                    idleTimeout: .seconds(5)
                ),
                executable: harness.executable,
                deadline: AntigravityRPCDeadline()
            ) { _ in
                operationRecorder.record()
                return true
            }
        }
        operation.cancel()
        await startGate.release()

        do {
            _ = try await operation.value
            XCTFail("Pre-cancelled request leased the running runtime")
        } catch let error as AntigravityManagedSessionError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertEqual(operationRecorder.count, 0)
        XCTAssertEqual(harness.launcher.launchCount, 1)
        await session.shutdown()
    }

    func testActiveLeasePreventsIdleTeardown()
        async throws
    {
        let operationGate = ManagedSessionGate()
        let harness = ManagedSessionHarness()
        let session = harness.makeSession()

        let operation = Task {
            try await session.withRuntime(
                authorization: .automatic(
                    idleTimeout: .milliseconds(30)
                ),
                executable: harness.executable,
                deadline: AntigravityRPCDeadline()
            ) { _ in
                await operationGate.wait()
                return true
            }
        }
        await operationGate.waitUntilWaiterArrives()
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(harness.handle.terminationCount, 0)

        await operationGate.release()
        let operationValue = try await operation.value
        XCTAssertTrue(operationValue)
        try await waitUntil {
            harness.handle.terminationCount == 1
        }
        XCTAssertEqual(harness.handle.terminationCount, 1)
    }

    func testLateLoginPromptAfterReadinessStopsIdleManagedProcess()
        async throws
    {
        let harness = ManagedSessionHarness()
        let session = harness.makeSession()

        let value = try await session.withRuntime(
            authorization: .automatic(idleTimeout: .seconds(5)),
            executable: harness.executable,
            deadline: AntigravityRPCDeadline()
        ) { _ in true }
        XCTAssertTrue(value)

        harness.handle.appendOutput(
            Data("How would you like to sign in?".utf8)
        )

        try await waitUntil {
            harness.handle.terminationCount == 1
        }
        XCTAssertEqual(harness.registry.unregisterCount, 1)
        await session.shutdown()
        XCTAssertEqual(harness.handle.terminationCount, 1)
    }

    func testResetWaitsForLeaseButShutdownForcesCleanup()
        async throws
    {
        let operationGate = ManagedSessionGate()
        let harness = ManagedSessionHarness()
        let session = harness.makeSession()
        let operation = Task {
            try await session.withRuntime(
                authorization: .automatic(
                    idleTimeout: .seconds(5)
                ),
                executable: harness.executable,
                deadline: AntigravityRPCDeadline()
            ) { _ in
                await operationGate.wait()
                return true
            }
        }
        await operationGate.waitUntilWaiterArrives()

        await session.reset(reason: .userRequested)
        XCTAssertEqual(harness.handle.terminationCount, 0)

        await session.shutdown()
        XCTAssertEqual(harness.handle.terminationCount, 1)
        XCTAssertEqual(harness.registry.unregisterCount, 1)

        await operationGate.release()
        let operationValue = try await operation.value
        XCTAssertTrue(operationValue)
        XCTAssertEqual(harness.handle.terminationCount, 1)
    }

    func testPendingResetRejectsNewLease()
        async throws
    {
        let operationGate = ManagedSessionGate()
        let harness = ManagedSessionHarness()
        let session = harness.makeSession()
        let activeOperation = Task {
            try await session.withRuntime(
                authorization: .automatic(
                    idleTimeout: .seconds(5)
                ),
                executable: harness.executable,
                deadline: AntigravityRPCDeadline()
            ) { _ in
                await operationGate.wait()
                return true
            }
        }
        await operationGate.waitUntilWaiterArrives()
        await session.reset(reason: .authenticationRequired)

        do {
            _ = try await session.withRuntime(
                authorization: .automatic(
                    idleTimeout: .seconds(5)
                ),
                executable: harness.executable,
                deadline: AntigravityRPCDeadline()
            ) { _ in true }
            XCTFail("reset이 예약된 runtime에 새 lease를 허용하면 안 됩니다")
        } catch let error as AntigravityManagedSessionError {
            XCTAssertEqual(error, .resetPending)
        }

        await operationGate.release()
        let activeOperationValue = try await activeOperation.value
        XCTAssertTrue(activeOperationValue)
        try await waitUntil {
            harness.handle.terminationCount == 1
        }
    }

    func testShutdownWaitsForInProgressCleanup()
        async throws
    {
        let terminationGate = ManagedSessionGate()
        let harness = ManagedSessionHarness(
            terminationGate: terminationGate
        )
        let session = harness.makeSession()

        let initialValue = try await session.withRuntime(
            authorization: .automatic(idleTimeout: .seconds(5)),
            executable: harness.executable,
            deadline: AntigravityRPCDeadline()
        ) { _ in true }
        XCTAssertTrue(initialValue)

        let resetTask = Task {
            await session.reset(reason: .userRequested)
        }
        await terminationGate.waitUntilWaiterArrives()

        let shutdownReturned = ManagedSessionGate()
        let shutdownTask = Task {
            await session.shutdown()
            await shutdownReturned.release()
        }
        let secondShutdownReturned = ManagedSessionGate()
        let secondShutdownTask = Task {
            await session.shutdown()
            await secondShutdownReturned.release()
        }
        await Task.yield()
        let returnedBeforeTermination = await shutdownReturned.isReleased
        let secondReturnedBeforeTermination =
            await secondShutdownReturned.isReleased
        XCTAssertFalse(returnedBeforeTermination)
        XCTAssertFalse(secondReturnedBeforeTermination)

        await terminationGate.release()
        await resetTask.value
        await shutdownTask.value
        await secondShutdownTask.value
        let returnedAfterTermination = await shutdownReturned.isReleased
        let secondReturnedAfterTermination =
            await secondShutdownReturned.isReleased
        XCTAssertTrue(returnedAfterTermination)
        XCTAssertTrue(secondReturnedAfterTermination)
        XCTAssertEqual(harness.handle.terminationCount, 1)
    }

    func testExplicitRecoveryUsesCrossProcessCoordinator()
        async throws
    {
        let harness = ManagedSessionHarness()
        let session = harness.makeSession()

        try await session.recoverOrphanedProcesses()

        XCTAssertEqual(harness.recovery.callCount, 1)
        XCTAssertEqual(harness.coordinator.callCount, 1)
    }

    func testExplicitRecoveryTimesOutWhenRealCoordinatorIsContended()
        async throws
    {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ClaudeUsageRecoveryContention-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let sessionCoordinator =
            AntigravityManagedLaunchFileCoordinator(
                directoryURL: directoryURL,
                retryDelayNanoseconds: 1_000_000
            )
        let contendingCoordinator =
            AntigravityManagedLaunchFileCoordinator(
                directoryURL: directoryURL,
                retryDelayNanoseconds: 1_000_000
            )
        let harness = ManagedSessionHarness()
        let session = harness.makeSession(
            launchCoordinator: sessionCoordinator,
            recoveryCoordinationTimeout: .milliseconds(40)
        )
        let lockAcquired = ManagedSessionGate()
        let releaseLock = ManagedSessionGate()
        let lockHolder = Task {
            try await contendingCoordinator.withExclusiveLaunch {
                await lockAcquired.release()
                await releaseLock.wait()
            }
        }
        await lockAcquired.wait()

        let clock = ContinuousClock()
        let startedAt = clock.now
        do {
            try await session.recoverOrphanedProcesses()
            XCTFail("Contended recovery unexpectedly acquired the lock")
        } catch let error as AntigravityManagedSessionError {
            XCTAssertEqual(
                error,
                .launchCoordinationUnavailable
            )
        }
        XCTAssertLessThan(
            startedAt.duration(to: clock.now),
            .seconds(1)
        )
        XCTAssertEqual(harness.recovery.callCount, 0)

        await releaseLock.release()
        _ = try await lockHolder.value
    }

    func testCleanupFallsBackWhenRealLaunchCoordinatorIsContended()
        async throws
    {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ClaudeUsageManagedSessionContention-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let sessionCoordinator =
            AntigravityManagedLaunchFileCoordinator(
                directoryURL: directoryURL,
                retryDelayNanoseconds: 1_000_000
            )
        let contendingCoordinator =
            AntigravityManagedLaunchFileCoordinator(
                directoryURL: directoryURL,
                retryDelayNanoseconds: 1_000_000
            )
        let harness = ManagedSessionHarness()
        let session = harness.makeSession(
            launchCoordinator: sessionCoordinator,
            cleanupCoordinationTimeout: .milliseconds(40)
        )

        _ = try await session.withRuntime(
            authorization: .automatic(idleTimeout: .seconds(5)),
            executable: harness.executable,
            deadline: AntigravityRPCDeadline()
        ) { _ in true }

        let lockAcquired = ManagedSessionGate()
        let releaseLock = ManagedSessionGate()
        let lockHolder = Task {
            try await contendingCoordinator.withExclusiveLaunch {
                await lockAcquired.release()
                await releaseLock.wait()
            }
        }
        await lockAcquired.wait()

        let clock = ContinuousClock()
        let startedAt = clock.now
        await session.reset(reason: .userRequested)
        let elapsed = startedAt.duration(to: clock.now)

        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertEqual(harness.handle.terminationCount, 1)
        XCTAssertEqual(
            harness.processTreeTerminator.terminationCount,
            0,
            "A timed-out coordinator must not enter the ledger transaction"
        )
        XCTAssertEqual(harness.registry.quarantineCount, 1)

        await releaseLock.release()
        _ = try await lockHolder.value
    }

    func testRecordSaveFailureCleansOwnedTreeAndNeverChecksReadiness()
        async throws
    {
        let harness = ManagedSessionHarness(
            recordSaveError:
                AntigravityManagedProcessRecordStoreError
                    .verificationFailed
        )
        let session = harness.makeSession()

        do {
            _ = try await session.withRuntime(
                authorization: .automatic(
                    idleTimeout: .seconds(5)
                ),
                executable: harness.executable,
                deadline: AntigravityRPCDeadline()
            ) { _ in true }
            XCTFail("Record persistence failure was ignored")
        } catch let error as AntigravityManagedSessionError {
            XCTAssertEqual(error, .recordPersistenceFailed)
        }

        XCTAssertEqual(harness.launcher.launchCount, 1)
        XCTAssertEqual(harness.handle.terminationCount, 1)
        XCTAssertEqual(harness.readiness.callCount, 0)
        XCTAssertEqual(harness.registry.registerCount, 0)
        let remainingIntentCount =
            harness.recordStore.intentCount
        XCTAssertEqual(remainingIntentCount, 0)
    }

    func testUncertainIntentCommitIsRolledBackWithoutSpawning()
        async throws
    {
        let harness = ManagedSessionHarness(
            createIntentErrorAfterCommit:
                AntigravityManagedProcessRecordStoreError
                    .verificationFailed
        )
        let session = harness.makeSession()

        do {
            _ = try await session.withRuntime(
                authorization: .automatic(
                    idleTimeout: .seconds(5)
                ),
                executable: harness.executable,
                deadline: AntigravityRPCDeadline()
            ) { _ in true }
            XCTFail("Uncertain intent commit unexpectedly spawned")
        } catch let error as AntigravityManagedSessionError {
            XCTAssertEqual(error, .recordPersistenceFailed)
        }

        XCTAssertEqual(harness.launcher.launchCount, 0)
        XCTAssertEqual(harness.recordStore.intentCount, 0)
        XCTAssertEqual(harness.handle.resumeCount, 0)
    }

    func testUncertainPromotionCommitCleansPersistedProcessWithoutResuming()
        async throws
    {
        let harness = ManagedSessionHarness(
            promoteErrorAfterCommit:
                AntigravityManagedProcessRecordStoreError
                    .verificationFailed
        )
        let session = harness.makeSession()

        do {
            _ = try await session.withRuntime(
                authorization: .automatic(
                    idleTimeout: .seconds(5)
                ),
                executable: harness.executable,
                deadline: AntigravityRPCDeadline()
            ) { _ in true }
            XCTFail("Uncertain promotion unexpectedly resumed user code")
        } catch let error as AntigravityManagedSessionError {
            XCTAssertEqual(error, .recordPersistenceFailed)
        }

        XCTAssertEqual(harness.handle.resumeCount, 0)
        XCTAssertEqual(harness.handle.terminationCount, 1)
        XCTAssertEqual(
            harness.processTreeTerminator.terminationCount,
            1
        )
        XCTAssertEqual(harness.recordStore.intentCount, 0)
        XCTAssertEqual(harness.recordStore.recordCount, 0)
        XCTAssertEqual(harness.readiness.callCount, 0)
    }

    func testCancellationAfterPromotionNeverResumesUserCode()
        async throws
    {
        let promoteGate = ManagedSessionSynchronousGate()
        let harness = ManagedSessionHarness(
            promoteGate: promoteGate
        )
        let session = harness.makeSession()
        let operation = Task {
            try await session.withRuntime(
                authorization: .automatic(
                    idleTimeout: .seconds(5)
                ),
                executable: harness.executable,
                deadline: AntigravityRPCDeadline()
            ) { _ in true }
        }

        try await promoteGate.waitUntilWaiterArrives()
        operation.cancel()
        try await promoteGate.waitUntilTaskIsCancelled()
        promoteGate.release()

        do {
            _ = try await operation.value
            XCTFail("Cancelled promoted launch resumed user code")
        } catch let error as AntigravityManagedSessionError {
            XCTAssertEqual(error, .cancelled)
        }

        XCTAssertEqual(harness.handle.resumeCount, 0)
        XCTAssertEqual(harness.handle.terminationCount, 1)
        XCTAssertEqual(harness.readiness.callCount, 0)
        XCTAssertEqual(harness.recordStore.recordCount, 0)
    }

    func testUnconfirmedPrePromotionTerminationPreservesLaunchIntent()
        async throws
    {
        let harness = ManagedSessionHarness(
            recordSaveError:
                AntigravityManagedProcessRecordStoreError
                    .verificationFailed,
            terminationEvidence: .unconfirmed
        )
        let session = harness.makeSession()

        do {
            _ = try await session.withRuntime(
                authorization: .automatic(
                    idleTimeout: .seconds(5)
                ),
                executable: harness.executable,
                deadline: AntigravityRPCDeadline()
            ) { _ in true }
            XCTFail("Unpersisted process unexpectedly became ready")
        } catch let error as AntigravityManagedSessionError {
            XCTAssertEqual(error, .recordPersistenceFailed)
        }

        XCTAssertEqual(harness.handle.terminationCount, 1)
        let remainingIntentCount =
            harness.recordStore.intentCount
        XCTAssertEqual(remainingIntentCount, 1)
        XCTAssertEqual(harness.readiness.callCount, 0)
    }

    func testProcessTreeIsObservedAfterResumeReadinessAndLastLease()
        async throws
    {
        let harness = ManagedSessionHarness()
        let session = harness.makeSession()

        let result = try await session.withRuntime(
            authorization: .automatic(idleTimeout: .seconds(5)),
            executable: harness.executable,
            deadline: AntigravityRPCDeadline()
        ) { _ in true }

        XCTAssertTrue(result)
        XCTAssertEqual(
            harness.processTreeTerminator.observationCount,
            3,
            "Expected post-resume, post-readiness, and last-lease observations"
        )
        await session.shutdown()
    }

    func testPeriodicIncompleteObservationRejectsNewLeaseAndCleansAfterLease()
        async throws
    {
        let operationGate = ManagedSessionGate()
        let harness = ManagedSessionHarness(
            processObservations: [
                .complete,
                .complete,
                .incomplete,
            ],
            processObservationInterval: .milliseconds(5)
        )
        let session = harness.makeSession()
        let active = Task {
            try await session.withRuntime(
                authorization: .automatic(
                    idleTimeout: .seconds(5)
                ),
                executable: harness.executable,
                deadline: AntigravityRPCDeadline()
            ) { _ in
                await operationGate.wait()
                return true
            }
        }
        await operationGate.waitUntilWaiterArrives()

        try await waitUntil {
            harness.processTreeTerminator.observationCount >= 3
        }
        XCTAssertEqual(harness.handle.terminationCount, 0)
        do {
            _ = try await session.withRuntime(
                authorization: .automatic(
                    idleTimeout: .seconds(5)
                ),
                executable: harness.executable,
                deadline: AntigravityRPCDeadline()
            ) { _ in true }
            XCTFail("Incomplete process observation allowed a new lease")
        } catch let error as AntigravityManagedSessionError {
            XCTAssertEqual(error, .resetPending)
        }

        await operationGate.release()
        let activeValue = try await active.value
        XCTAssertTrue(activeValue)
        try await waitUntil {
            harness.handle.terminationCount == 1
        }
    }

    func testIncompleteInitialObservationNeverStartsReadiness()
        async throws
    {
        let harness = ManagedSessionHarness(
            processObservations: [.incomplete]
        )
        let session = harness.makeSession()

        do {
            _ = try await session.withRuntime(
                authorization: .automatic(
                    idleTimeout: .seconds(5)
                ),
                executable: harness.executable,
                deadline: AntigravityRPCDeadline()
            ) { _ in true }
            XCTFail("Incomplete initial tree observation was ignored")
        } catch let error as AntigravityManagedSessionError {
            XCTAssertEqual(error, .recordRecoveryBlocked)
        }

        XCTAssertEqual(harness.readiness.callCount, 0)
        XCTAssertEqual(harness.handle.terminationCount, 1)
        XCTAssertEqual(
            harness.processTreeTerminator.observationCount,
            1
        )
    }

    func testIncompleteObservationDuringReadinessCancelsLaunch()
        async throws
    {
        let harness = ManagedSessionHarness(
            readinessDelay: .seconds(60),
            processObservations: [
                .complete,
                .incomplete,
            ],
            processObservationInterval: .milliseconds(5)
        )
        let session = harness.makeSession()

        do {
            _ = try await session.withRuntime(
                authorization: .automatic(
                    idleTimeout: .seconds(5)
                ),
                executable: harness.executable,
                deadline: AntigravityRPCDeadline()
            ) { _ in true }
            XCTFail("Incomplete readiness observation was ignored")
        } catch let error as AntigravityManagedSessionError {
            XCTAssertEqual(error, .recordRecoveryBlocked)
        }

        XCTAssertEqual(harness.readiness.callCount, 1)
        XCTAssertEqual(harness.handle.terminationCount, 1)
        XCTAssertGreaterThanOrEqual(
            harness.processTreeTerminator.observationCount,
            2
        )
    }

    func testIncompleteCleanupQuarantinesManagedRuntime()
        async throws
    {
        let harness = ManagedSessionHarness(
            cleanupResult: .incomplete
        )
        let session = harness.makeSession()

        let result = try await session.withRuntime(
            authorization: .automatic(
                idleTimeout: .seconds(5)
            ),
            executable: harness.executable,
            deadline: AntigravityRPCDeadline()
        ) { _ in true }
        XCTAssertTrue(result)

        await session.shutdown()

        XCTAssertEqual(harness.registry.quarantineCount, 1)
        XCTAssertEqual(harness.registry.unregisterCount, 0)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Condition timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class ManagedSessionHarness {
    let executable: AntigravityCanonicalExecutable
    let childIdentity: AntigravityVerifiedProcessIdentity
    let handle: ManagedSessionProcessHandleStub
    let launcher: ManagedSessionProcessLauncherStub
    let identityProvider: ManagedSessionIdentityProviderStub
    let recordStore: ManagedSessionRecordStoreStub
    let processTreeTerminator:
        ManagedSessionProcessTreeTerminatorStub
    let coordinator = ManagedSessionLaunchCoordinatorStub()
    let recovery = ManagedSessionRecoveryStub()
    let registry = ManagedSessionRegistryStub()
    let readiness: ManagedSessionReadinessStub
    let processObservationInterval: Duration

    init(
        readinessGate: ManagedSessionGate? = nil,
        readinessDelay: Duration? = nil,
        terminationGate: ManagedSessionGate? = nil,
        recordSaveError: Error? = nil,
        createIntentErrorAfterCommit: Error? = nil,
        promoteErrorAfterCommit: Error? = nil,
        promoteGate: ManagedSessionSynchronousGate? = nil,
        terminationEvidence:
            AntigravityManagedCLIProcessTerminationEvidence =
                .confirmed,
        cleanupResult:
            AntigravityManagedProcessCleanupResult = .complete,
        processObservations:
            [AntigravityManagedProcessObservationResult] = [],
        processObservationInterval: Duration = .seconds(60)
    ) {
        self.processObservationInterval =
            processObservationInterval
        executable = AntigravityCanonicalExecutable(
            canonicalURL: URL(
                fileURLWithPath: "/usr/local/bin/agy"
            ),
            role: .agyCLI
        )
        childIdentity = AntigravityVerifiedProcessIdentity(
            processID: 6_101,
            effectiveUserID: AntigravityUserID(rawValue: 501),
            realUserID: AntigravityUserID(rawValue: 501),
            startedAt: AntigravityProcessStartTime(
                seconds: 6_101,
                microseconds: 1
            )!,
            executable: executable
        )!
        handle = ManagedSessionProcessHandleStub(
            processID: childIdentity.processID,
            terminationGate: terminationGate,
            terminationEvidence: terminationEvidence
        )
        launcher = ManagedSessionProcessLauncherStub(
            handle: handle
        )
        let childKernelIdentity =
            AntigravityKernelProcessIdentity(
                uniqueID: 16_101,
                parentUniqueID: 15_000,
                pidVersion: 106_101
            )!
        identityProvider = ManagedSessionIdentityProviderStub(
            child: AntigravityRecordedProcessIdentity(
                pid: childIdentity.processID,
                effectiveUserID:
                    childIdentity.effectiveUserID.rawValue,
                realUserID:
                    childIdentity.realUserID.rawValue,
                startedAtSeconds:
                    childIdentity.startedAt.seconds,
                startedAtMicroseconds:
                    childIdentity.startedAt.microseconds,
                executablePath:
                    childIdentity.executable.canonicalURL.path,
                kernelIdentity: childKernelIdentity
            )!,
            owner: AntigravityRecordedProcessIdentity(
                pid: Int32(getpid()),
                effectiveUserID: 501,
                realUserID: 501,
                startedAtSeconds: 5_000,
                startedAtMicroseconds: 1,
                executablePath: "/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage",
                kernelIdentity:
                    AntigravityKernelProcessIdentity(
                        uniqueID: 15_000,
                        parentUniqueID: 14_000,
                        pidVersion: 105_000
                    )!
            )!
        )
        recordStore = ManagedSessionRecordStoreStub(
            saveError: recordSaveError,
            createIntentErrorAfterCommit:
                createIntentErrorAfterCommit,
            promoteErrorAfterCommit:
                promoteErrorAfterCommit,
            promoteGate: promoteGate
        )
        processTreeTerminator =
            ManagedSessionProcessTreeTerminatorStub(
                recordStore: recordStore,
                observations: processObservations,
                cleanupResult: cleanupResult
            )
        readiness = ManagedSessionReadinessStub(
            identity: childIdentity,
            gate: readinessGate,
            delay: readinessDelay
        )
    }

    func makeSession(
        executableRevalidator:
            any AntigravityExecutableRevalidating =
                ManagedSessionExecutableRevalidatorStub(),
        launchCoordinator:
            (any AntigravityManagedLaunchCoordinating)? = nil,
        cleanupCoordinationTimeout: Duration = .seconds(1),
        recoveryCoordinationTimeout: Duration = .seconds(2)
    ) -> AntigravityManagedCLISession {
        AntigravityManagedCLISession(
            launcher: launcher,
            executableRevalidator: executableRevalidator,
            identityProvider: identityProvider,
            recordStore: recordStore,
            launchCoordinator:
                launchCoordinator ?? coordinator,
            recovery: recovery,
            processTreeController: processTreeTerminator,
            registry: registry,
            readinessChecker: readiness,
            environment: AntigravityManagedCLIEnvironment(
                homeDirectory: URL(fileURLWithPath: "/Users/test"),
                userName: "test"
            ),
            currentDirectoryURL: URL(fileURLWithPath: "/Users/test"),
            now: { Date(timeIntervalSince1970: 100) },
            monitorInterval: .milliseconds(5),
            processObservationInterval:
                processObservationInterval,
            terminationGracePeriod: .zero,
            cleanupCoordinationTimeout:
                cleanupCoordinationTimeout,
            recoveryCoordinationTimeout:
                recoveryCoordinationTimeout
        )
    }
}

private struct ManagedSessionExecutableRevalidatorStub:
    AntigravityExecutableRevalidating
{
    func isCurrent(
        _ executable: AntigravityCanonicalExecutable
    ) -> Bool {
        true
    }
}

private final class ManagedSessionScriptedExecutableRevalidator:
    AntigravityExecutableRevalidating,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var results: [Bool]
    private var recordedCallCount = 0

    init(results: [Bool]) {
        precondition(!results.isEmpty)
        self.results = results
    }

    var callCount: Int {
        lock.withLock { recordedCallCount }
    }

    func isCurrent(
        _ executable: AntigravityCanonicalExecutable
    ) -> Bool {
        lock.withLock {
            recordedCallCount += 1
            if results.count > 1 {
                return results.removeFirst()
            }
            return results[0]
        }
    }
}

private final class ManagedSessionProcessTreeTerminatorStub:
    AntigravityManagedProcessTreeControlling,
    @unchecked Sendable
{
    private let recordStore: ManagedSessionRecordStoreStub
    private let lock = NSLock()
    private var observations:
        [AntigravityManagedProcessObservationResult]
    private let cleanupResult:
        AntigravityManagedProcessCleanupResult
    private var recordedObservationCount = 0
    private var recordedTerminationCount = 0

    init(
        recordStore: ManagedSessionRecordStoreStub,
        observations:
            [AntigravityManagedProcessObservationResult],
        cleanupResult:
            AntigravityManagedProcessCleanupResult
    ) {
        self.recordStore = recordStore
        self.observations = observations
        self.cleanupResult = cleanupResult
    }

    var observationCount: Int {
        lock.withLock { recordedObservationCount }
    }

    var terminationCount: Int {
        lock.withLock { recordedTerminationCount }
    }

    func observe(
        sessionID: UUID
    ) async -> AntigravityManagedProcessObservationResult {
        lock.withLock {
            recordedObservationCount += 1
            guard !observations.isEmpty else {
                return .complete
            }
            return observations.removeFirst()
        }
    }

    func terminate(
        sessionID: UUID,
        handle: any AntigravityManagedCLIProcessHandling,
        gracePeriod: Duration
    ) async -> AntigravityManagedProcessCleanupResult {
        lock.withLock {
            recordedTerminationCount += 1
        }
        _ = await handle.terminateTree(gracePeriod: gracePeriod)
        guard cleanupResult == .complete else {
            return cleanupResult
        }
        do {
            try recordStore.remove(sessionID: sessionID)
        } catch {
            return .recordRemovalFailed
        }
        return .complete
    }
}

private final class ManagedSessionProcessHandleStub:
    AntigravityManagedCLIProcessHandling,
    @unchecked Sendable
{
    let processID: Int32
    let processGroupID: Int32
    private let lock = NSLock()
    private let terminationGate: ManagedSessionGate?
    private let terminationEvidence:
        AntigravityManagedCLIProcessTerminationEvidence
    private var recordedTerminationCount = 0
    private var recordedResumeCount = 0
    private var output = Data()

    init(
        processID: Int32,
        terminationGate: ManagedSessionGate?,
        terminationEvidence:
            AntigravityManagedCLIProcessTerminationEvidence
    ) {
        self.processID = processID
        self.processGroupID = processID
        self.terminationGate = terminationGate
        self.terminationEvidence = terminationEvidence
    }

    var terminationCount: Int {
        lock.withLock { recordedTerminationCount }
    }

    var resumeCount: Int {
        lock.withLock { recordedResumeCount }
    }

    func resume() throws {
        lock.withLock {
            recordedResumeCount += 1
        }
    }

    func drainOutput(maximumBytes: Int) -> Data {
        lock.withLock {
            let count = min(maximumBytes, output.count)
            let drained = output.prefix(count)
            output.removeFirst(count)
            return Data(drained)
        }
    }

    func terminationStatus() -> Int32? {
        nil
    }

    func appendOutput(_ data: Data) {
        lock.withLock {
            output.append(data)
        }
    }

    func terminateTree(
        gracePeriod: Duration
    ) async -> AntigravityManagedCLIProcessTerminationEvidence {
        lock.withLock {
            recordedTerminationCount += 1
        }
        if let terminationGate {
            await terminationGate.wait()
        }
        return terminationEvidence
    }
}

private final class ManagedSessionProcessLauncherStub:
    AntigravityManagedCLIProcessLaunching,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let handle: ManagedSessionProcessHandleStub
    private var recordedLaunchCount = 0

    init(handle: ManagedSessionProcessHandleStub) {
        self.handle = handle
    }

    var launchCount: Int {
        lock.withLock { recordedLaunchCount }
    }

    func launchSuspended(
        _ request: AntigravityManagedCLIProcessLaunchRequest
    ) throws -> any AntigravityManagedCLIProcessHandling {
        lock.withLock {
            recordedLaunchCount += 1
        }
        return handle
    }
}

private final class ManagedSessionIdentityProviderStub:
    AntigravityManagedProcessIdentityProviding,
    @unchecked Sendable
{
    let child: AntigravityRecordedProcessIdentity
    let owner: AntigravityRecordedProcessIdentity

    init(
        child: AntigravityRecordedProcessIdentity,
        owner: AntigravityRecordedProcessIdentity
    ) {
        self.child = child
        self.owner = owner
    }

    func identity(
        for processID: Int32
    ) -> AntigravityRecordedProcessIdentity? {
        switch processID {
        case child.pid:
            child
        case Int32(getpid()):
            owner
        default:
            nil
        }
    }

    func processGroupID(for processID: Int32) -> Int32? {
        processID == child.pid ? child.pid : nil
    }
}

private final class ManagedSessionRecordStoreStub:
    AntigravityManagedProcessLedgerStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let saveError: Error?
    private let createIntentErrorAfterCommit: Error?
    private let promoteErrorAfterCommit: Error?
    private let promoteGate: ManagedSessionSynchronousGate?
    private var records: [UUID: AntigravityManagedProcessRecord] = [:]
    private var intents: [UUID: AntigravityManagedLaunchIntent] = [:]
    private var recordedSaveCount = 0
    private var revision: UInt64 = 0

    init(
        saveError: Error?,
        createIntentErrorAfterCommit: Error?,
        promoteErrorAfterCommit: Error?,
        promoteGate: ManagedSessionSynchronousGate?
    ) {
        self.saveError = saveError
        self.createIntentErrorAfterCommit =
            createIntentErrorAfterCommit
        self.promoteErrorAfterCommit =
            promoteErrorAfterCommit
        self.promoteGate = promoteGate
    }

    var saveCount: Int {
        lock.withLock { recordedSaveCount }
    }

    var intentCount: Int {
        lock.withLock { intents.count }
    }

    var recordCount: Int {
        lock.withLock { records.count }
    }

    func load() throws -> [AntigravityManagedProcessRecord] {
        lock.withLock { Array(records.values) }
    }

    func loadLedger() throws
        -> AntigravityManagedProcessLedgerSnapshot
    {
        lock.withLock {
            let entries =
                intents.values.map {
                    AntigravityManagedProcessLedgerEntry
                        .launchIntent($0)
                }
                + records.values.map {
                    AntigravityManagedProcessLedgerEntry
                        .processRecord($0)
                }
            return AntigravityManagedProcessLedgerSnapshot(
                bootSessionID:
                    entries.first?.bootSessionID,
                revision: revision,
                entries: entries
            )
        }
    }

    func createIntent(
        _ intent: AntigravityManagedLaunchIntent
    ) throws {
        try lock.withLock {
            intents[intent.sessionID] = intent
            revision += 1
            if let createIntentErrorAfterCommit {
                throw createIntentErrorAfterCommit
            }
        }
    }

    func promoteIntent(
        _ intent: AntigravityManagedLaunchIntent,
        to record: AntigravityManagedProcessRecord
    ) throws {
        try lock.withLock {
            recordedSaveCount += 1
            if let saveError {
                throw saveError
            }
            guard intents.removeValue(
                forKey: intent.sessionID
            ) == intent else {
                throw AntigravityManagedProcessRecordStoreError
                    .entryNotFound
            }
            records[record.sessionID] = record
            revision += 1
        }
        promoteGate?.wait()
        if let promoteErrorAfterCommit {
            throw promoteErrorAfterCommit
        }
    }

    func update(_ record: AntigravityManagedProcessRecord) throws {
        try lock.withLock {
            if let saveError {
                throw saveError
            }
            records[record.sessionID] = record
            revision += 1
        }
    }

    func remove(sessionID: UUID) throws {
        _ = lock.withLock {
            records.removeValue(forKey: sessionID)
            revision += 1
        }
    }

    func removeIntent(
        _ intent: AntigravityManagedLaunchIntent
    ) throws {
        _ = lock.withLock {
            intents.removeValue(forKey: intent.sessionID)
            revision += 1
        }
    }

    func removeEntriesFromStaleBoot(
        _ bootSessionID: AntigravityBootSessionID
    ) throws {
        lock.withLock {
            intents.removeAll()
            records.removeAll()
            revision += 1
        }
    }
}

private final class ManagedSessionLaunchCoordinatorStub:
    AntigravityManagedLaunchCoordinating,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var recordedCallCount = 0

    var callCount: Int {
        lock.withLock { recordedCallCount }
    }

    nonisolated func withExclusiveLaunch<T: Sendable>(
        _ operation:
            nonisolated(nonsending)
            @Sendable () async throws -> T
    ) async throws -> T {
        lock.withLock {
            recordedCallCount += 1
        }
        return try await operation()
    }
}

private final class ManagedSessionRecoveryStub:
    AntigravityManagedSessionLifecycleRecovering,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var recordedCallCount = 0

    var callCount: Int {
        lock.withLock { recordedCallCount }
    }

    func recoverOrphanedProcesses() async throws {
        lock.withLock {
            recordedCallCount += 1
        }
    }

    func prepareForLaunch(
        owner: AntigravityRecordedProcessIdentity,
        executable: AntigravityManagedExecutableDescriptor
    ) async throws -> AntigravityBootSessionID {
        lock.withLock {
            recordedCallCount += 1
        }
        return AntigravityBootSessionID(
            rawValue: UUID(
                uuidString:
                    "00000000-0000-0000-0000-000000000601"
            )!
        )
    }
}

private final class ManagedSessionRegistryStub:
    AntigravityManagedRuntimeRegistering,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var recordedRegisterCount = 0
    private var recordedUnregisterCount = 0
    private var recordedQuarantineCount = 0

    var registerCount: Int {
        lock.withLock { recordedRegisterCount }
    }

    var unregisterCount: Int {
        lock.withLock { recordedUnregisterCount }
    }

    var quarantineCount: Int {
        lock.withLock { recordedQuarantineCount }
    }

    func register(
        _ identity: AntigravityVerifiedProcessIdentity
    ) async {
        lock.withLock {
            recordedRegisterCount += 1
        }
    }

    func unregister(
        _ identity: AntigravityVerifiedProcessIdentity
    ) async {
        lock.withLock {
            recordedUnregisterCount += 1
        }
    }

    func quarantine(
        _ identity: AntigravityVerifiedProcessIdentity
    ) async {
        lock.withLock {
            recordedQuarantineCount += 1
        }
    }
}

private final class ManagedSessionReadinessStub:
    AntigravityManagedCLIReadinessChecking,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let identity: AntigravityVerifiedProcessIdentity
    private let gate: ManagedSessionGate?
    private let delay: Duration?
    private var recordedCallCount = 0

    init(
        identity: AntigravityVerifiedProcessIdentity,
        gate: ManagedSessionGate?,
        delay: Duration?
    ) {
        self.identity = identity
        self.gate = gate
        self.delay = delay
    }

    var callCount: Int {
        lock.withLock { recordedCallCount }
    }

    func waitUntilReady(
        handle: any AntigravityManagedCLIProcessHandling,
        processIdentity: AntigravityVerifiedProcessIdentity,
        deadline: AntigravityRPCDeadline
    ) async throws -> AntigravityManagedCLIReadinessResult {
        lock.withLock {
            recordedCallCount += 1
        }
        if let delay {
            try await Task.sleep(for: delay)
        }
        if let gate {
            await gate.wait()
        }
        let endpoint = AntigravityVerifiedRuntimeEndpoint(
            processIdentity: identity,
            host: .ipv4,
            port: AntigravityTCPPort(45_321)!,
            transport: .agyCLI,
            ownership: .managed,
            authentication: .cliTokenless
        )!
        return AntigravityManagedCLIReadinessResult(
            runtime: AntigravityManagedRuntime(
                processIdentity: identity,
                endpoint: endpoint
            )!,
            diagnostics: AntigravityManagedSessionDiagnostics(
                interactions: [],
                outputWasTruncated: false
            )
        )
    }
}

private actor ManagedSessionGate {
    private var released = false
    private var waiters:
        [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters:
        [CheckedContinuation<Void, Never>] = []

    var isReleased: Bool {
        released
    }

    func wait() async {
        if released { return }
        let pendingArrivals = arrivalWaiters
        arrivalWaiters.removeAll()
        for continuation in pendingArrivals {
            continuation.resume()
        }
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func waitUntilWaiterArrives() async {
        if !waiters.isEmpty { return }
        await withCheckedContinuation { continuation in
            if !waiters.isEmpty {
                continuation.resume()
            } else {
                arrivalWaiters.append(continuation)
            }
        }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private final class ManagedSessionOperationRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var recordedCount = 0

    var count: Int {
        lock.withLock { recordedCount }
    }

    func record() {
        lock.withLock {
            recordedCount += 1
        }
    }
}

/// Synchronous protocol boundaries cannot await the actor gate. This latch is
/// used only to hold a deterministic store transition while the request task
/// is cancelled.
private final class ManagedSessionSynchronousGate:
    @unchecked Sendable
{
    private let condition = NSCondition()
    private var waiterArrived = false
    private var waiterObservedCancellation = false
    private var released = false

    func wait() {
        condition.lock()
        waiterArrived = true
        condition.broadcast()
        while !released {
            if Task.isCancelled {
                waiterObservedCancellation = true
                condition.broadcast()
            }
            _ = condition.wait(
                until: Date().addingTimeInterval(0.005)
            )
        }
        condition.unlock()
    }

    func waitUntilWaiterArrives() async throws {
        let deadline = ContinuousClock.now.advanced(
            by: .seconds(2)
        )
        while ContinuousClock.now < deadline {
            condition.lock()
            let arrived = waiterArrived
            condition.unlock()
            if arrived { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Synchronous gate received no waiter")
    }

    func waitUntilTaskIsCancelled() async throws {
        let deadline = ContinuousClock.now.advanced(
            by: .seconds(2)
        )
        while ContinuousClock.now < deadline {
            condition.lock()
            let observed = waiterObservedCancellation
            condition.unlock()
            if observed { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Synchronous waiter did not observe cancellation")
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
