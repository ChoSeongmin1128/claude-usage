import Darwin
import Foundation
import XCTest
@testable import ClaudeUsage

final class AntigravityManagedLaunchCoordinatorTests: XCTestCase {
    func testCoordinatorsForSamePathNeverOverlap() async throws {
        let harness = try LaunchCoordinatorHarness()
        defer { harness.cleanup() }
        let firstCoordinator = harness.makeCoordinator()
        let secondCoordinator = harness.makeCoordinator()
        let firstEntered = AsyncLatch()
        let releaseFirst = AsyncLatch()
        let secondAttempted = AsyncLatch()
        let secondEntered = AsyncLatch()
        let probe = CriticalSectionProbe()

        let firstTask = Task {
            try await firstCoordinator.withExclusiveLaunch {
                await probe.enter()
                await firstEntered.signal()
                await releaseFirst.wait()
                await probe.leave()
            }
        }
        await firstEntered.wait()

        let secondTask = Task {
            await secondAttempted.signal()
            try await secondCoordinator.withExclusiveLaunch {
                await probe.enter()
                await secondEntered.signal()
                await probe.leave()
            }
        }
        await secondAttempted.wait()

        // Give the second coordinator multiple nonblocking flock attempts while
        // the first descriptor remains locked.
        try await Task<Never, Never>.sleep(nanoseconds: 75_000_000)
        let enteredBeforeRelease = await secondEntered.isSignaled
        let maximumBeforeRelease = await probe.maximumActiveCount
        XCTAssertFalse(enteredBeforeRelease)
        XCTAssertEqual(maximumBeforeRelease, 1)

        await releaseFirst.signal()
        try await firstTask.value
        try await secondTask.value

        let enteredAfterRelease = await secondEntered.isSignaled
        let maximumAfterRelease = await probe.maximumActiveCount
        let activeAfterRelease = await probe.activeCount
        XCTAssertTrue(enteredAfterRelease)
        XCTAssertEqual(maximumAfterRelease, 1)
        XCTAssertEqual(activeAfterRelease, 0)
    }

    func testIndependentProcessLockIsReleasedAfterSIGKILL()
        async throws
    {
        let harness = try LaunchCoordinatorHarness(
            createDirectory: true
        )
        defer { harness.cleanup() }
        let holder = Process()
        let output = Pipe()
        holder.executableURL = URL(
            fileURLWithPath: "/usr/bin/perl"
        )
        holder.arguments = [
            "-e",
            """
            my $path = shift @ARGV;
            open(my $fh, ">>", $path) or die "open: $!";
            chmod(0600, $path) or die "chmod: $!";
            flock($fh, 2) or die "flock: $!";
            select(STDOUT); $| = 1;
            print "locked\\n";
            sleep 60;
            """,
            harness.lockFileURL.path,
        ]
        holder.standardOutput = output
        holder.standardError = output
        try holder.run()
        defer {
            if holder.isRunning {
                _ = Darwin.kill(
                    Int32(holder.processIdentifier),
                    SIGKILL
                )
                holder.waitUntilExit()
            }
        }

        let markerData =
            output.fileHandleForReading.availableData
        let marker = String(
            data: markerData,
            encoding: .utf8
        )
        XCTAssertEqual(marker, "locked\n")
        guard marker == "locked\n" else { return }

        let coordinator = harness.makeCoordinator()
        do {
            _ = try await coordinator.withExclusiveLaunch(
                deadline: AntigravityRPCDeadline(
                    totalTimeout: .milliseconds(40),
                    discoveryTimeout: .milliseconds(40)
                )
            ) {
                true
            }
            XCTFail("A separately held flock was ignored")
        } catch let error as AntigravityRPCDeadlineError {
            XCTAssertEqual(error, .timedOut(.request))
        }

        XCTAssertEqual(
            Darwin.kill(
                Int32(holder.processIdentifier),
                SIGKILL
            ),
            0
        )
        holder.waitUntilExit()

        let acquired = try await coordinator.withExclusiveLaunch(
            deadline: AntigravityRPCDeadline(
                totalTimeout: .seconds(1),
                discoveryTimeout: .seconds(1)
            )
        ) {
            true
        }
        XCTAssertTrue(acquired)
    }

    func testCancellationReleasesLockForNextCoordinator() async throws {
        let harness = try LaunchCoordinatorHarness()
        defer { harness.cleanup() }
        let holder = harness.makeCoordinator()
        let follower = harness.makeCoordinator()
        let entered = AsyncLatch()

        let cancelledTask = Task {
            try await holder.withExclusiveLaunch {
                await entered.signal()
                try await Task<Never, Never>.sleep(nanoseconds: 60_000_000_000)
            }
        }
        await entered.wait()
        cancelledTask.cancel()

        do {
            try await cancelledTask.value
            XCTFail("취소된 임계구간은 성공하면 안 됩니다")
        } catch is CancellationError {
            // Expected.
        }

        let result = try await follower.withExclusiveLaunch { "released" }
        XCTAssertEqual(result, "released")
    }

    func testDeadlineExpiresWhileWaitingWithoutEnteringOperation()
        async throws
    {
        let harness = try LaunchCoordinatorHarness()
        defer { harness.cleanup() }
        let holder = harness.makeCoordinator()
        let follower = harness.makeCoordinator()
        let holderEntered = AsyncLatch()
        let releaseHolder = AsyncLatch()
        let followerEntered = AsyncLatch()

        let holderTask = Task {
            try await holder.withExclusiveLaunch {
                await holderEntered.signal()
                await releaseHolder.wait()
            }
        }
        await holderEntered.wait()

        do {
            _ = try await follower.withExclusiveLaunch(
                deadline: AntigravityRPCDeadline(
                    totalTimeout: .milliseconds(35),
                    discoveryTimeout: .milliseconds(35)
                )
            ) {
                await followerEntered.signal()
                return true
            }
            XCTFail("만료된 lock waiter가 임계구간에 진입하면 안 됩니다")
        } catch let error as AntigravityRPCDeadlineError {
            XCTAssertEqual(error, .timedOut(.request))
        }

        let enteredAfterDeadline = await followerEntered.isSignaled
        XCTAssertFalse(enteredAfterDeadline)
        await releaseHolder.signal()
        try await holderTask.value
    }

    func testThrownOperationReleasesLockForNextCoordinator() async throws {
        let harness = try LaunchCoordinatorHarness()
        defer { harness.cleanup() }
        let firstCoordinator = harness.makeCoordinator()
        let secondCoordinator = harness.makeCoordinator()

        do {
            _ = try await firstCoordinator.withExclusiveLaunch { () -> Bool in
                throw ExpectedLaunchFailure.failed
            }
            XCTFail("operation 오류가 전달되어야 합니다")
        } catch let error as ExpectedLaunchFailure {
            XCTAssertEqual(error, .failed)
        }

        let result = try await secondCoordinator.withExclusiveLaunch { true }
        XCTAssertTrue(result)
    }

    func testRejectsSymlinkLockFileAndSymlinkDirectory() async throws {
        let fileHarness = try LaunchCoordinatorHarness(createDirectory: true)
        defer { fileHarness.cleanup() }
        let target = fileHarness.rootURL.appendingPathComponent("target.lock")
        try Data().write(to: target)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: target.path
        )
        try FileManager.default.createSymbolicLink(
            at: fileHarness.lockFileURL,
            withDestinationURL: target
        )

        do {
            _ = try await fileHarness.makeCoordinator()
                .withExclusiveLaunch { true }
            XCTFail("symlink lock file을 허용하면 안 됩니다")
        } catch let error as AntigravityManagedLaunchCoordinatorError {
            XCTAssertEqual(error, .invalidLockFile)
        }

        let directoryHarness = try LaunchCoordinatorHarness()
        defer { directoryHarness.cleanup() }
        let actualDirectory = directoryHarness.rootURL
            .appendingPathComponent("actual", isDirectory: true)
        try FileManager.default.createDirectory(
            at: actualDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(
            at: directoryHarness.directoryURL,
            withDestinationURL: actualDirectory
        )

        do {
            _ = try await directoryHarness.makeCoordinator()
                .withExclusiveLaunch { true }
            XCTFail("symlink directory를 허용하면 안 됩니다")
        } catch let error as AntigravityManagedLaunchCoordinatorError {
            XCTAssertEqual(error, .invalidDirectory)
        }
    }

    func testHardensSameOwnerDirectoryButRejectsInsecureLockFilePermissions()
        async throws
    {
        let directoryHarness = try LaunchCoordinatorHarness(
            createDirectory: true
        )
        defer { directoryHarness.cleanup() }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: directoryHarness.directoryURL.path
        )

        let hardened = try await directoryHarness.makeCoordinator()
            .withExclusiveLaunch { true }
        XCTAssertTrue(hardened)
        let hardenedMetadata = try metadata(
            at: directoryHarness.directoryURL
        )
        XCTAssertEqual(
            posixPermissions(hardenedMetadata.st_mode),
            0o700
        )

        let fileHarness = try LaunchCoordinatorHarness(createDirectory: true)
        defer { fileHarness.cleanup() }
        try Data().write(to: fileHarness.lockFileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fileHarness.lockFileURL.path
        )

        do {
            _ = try await fileHarness.makeCoordinator()
                .withExclusiveLaunch { true }
            XCTFail("공개된 lock file mode를 자동 보정하면 안 됩니다")
        } catch let error as AntigravityManagedLaunchCoordinatorError {
            XCTAssertEqual(error, .invalidLockFilePermissions)
        }
    }

    func testRejectsUnexpectedOwnerAndCreatesPrivateRegularLockFile() async throws {
        let ownerHarness = try LaunchCoordinatorHarness(createDirectory: true)
        defer { ownerHarness.cleanup() }
        let unexpectedOwner = geteuid() == uid_t.max ? geteuid() - 1 : geteuid() + 1
        let wrongOwnerCoordinator = ownerHarness.makeCoordinator(
            expectedUserID: unexpectedOwner
        )

        do {
            _ = try await wrongOwnerCoordinator.withExclusiveLaunch { true }
            XCTFail("예상 owner와 다른 directory를 허용하면 안 됩니다")
        } catch let error as AntigravityManagedLaunchCoordinatorError {
            XCTAssertEqual(error, .invalidDirectoryOwner)
        }

        let creationHarness = try LaunchCoordinatorHarness()
        defer { creationHarness.cleanup() }
        let result = try await creationHarness.makeCoordinator()
            .withExclusiveLaunch { 42 }
        XCTAssertEqual(result, 42)

        let directoryMetadata = try metadata(at: creationHarness.directoryURL)
        XCTAssertEqual(directoryMetadata.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(posixPermissions(directoryMetadata.st_mode), 0o700)
        XCTAssertEqual(directoryMetadata.st_uid, geteuid())

        let fileMetadata = try metadata(at: creationHarness.lockFileURL)
        XCTAssertEqual(fileMetadata.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(posixPermissions(fileMetadata.st_mode), 0o600)
        XCTAssertEqual(fileMetadata.st_uid, geteuid())
        XCTAssertEqual(fileMetadata.st_nlink, 1)
    }

    func testWaitingCoordinatorRejectsReplacedLockPath() async throws {
        let harness = try LaunchCoordinatorHarness()
        defer { harness.cleanup() }
        let holder = harness.makeCoordinator()
        let waiter = harness.makeCoordinator()
        let holderEntered = AsyncLatch()
        let releaseHolder = AsyncLatch()
        let waiterAttempted = AsyncLatch()
        let waiterEntered = AsyncLatch()

        let holderTask = Task {
            try await holder.withExclusiveLaunch {
                await holderEntered.signal()
                await releaseHolder.wait()
            }
        }
        await holderEntered.wait()

        let originalLockMetadata = try metadata(
            at: harness.lockFileURL
        )
        let waiterTask = Task {
            await waiterAttempted.signal()
            try await waiter.withExclusiveLaunch {
                await waiterEntered.signal()
            }
        }
        await waiterAttempted.wait()

        let waiterOpenedOriginalLock =
            await waitForOpenDescriptorCount(
                matching: originalLockMetadata,
                atLeast: 2
            )
        XCTAssertTrue(
            waiterOpenedOriginalLock,
            "waiter가 기존 lock inode를 연 상태여야 합니다"
        )

        let movedLockURL = harness.directoryURL
            .appendingPathComponent("moved-launch.lock")
        try FileManager.default.moveItem(
            at: harness.lockFileURL,
            to: movedLockURL
        )
        try Data().write(to: harness.lockFileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: harness.lockFileURL.path
        )

        await releaseHolder.signal()
        try await holderTask.value

        do {
            try await waiterTask.value
            XCTFail("교체된 lock pathname으로 임계구간에 진입하면 안 됩니다")
        } catch let error as AntigravityManagedLaunchCoordinatorError {
            XCTAssertEqual(error, .invalidLockFile)
        }
        let enteredReplacedLock = await waiterEntered.isSignaled
        XCTAssertFalse(enteredReplacedLock)
    }

    func testWaitingCoordinatorRejectsReplacedDirectoryPath() async throws {
        let harness = try LaunchCoordinatorHarness()
        defer { harness.cleanup() }
        let holder = harness.makeCoordinator()
        let waiter = harness.makeCoordinator()
        let holderEntered = AsyncLatch()
        let releaseHolder = AsyncLatch()
        let waiterAttempted = AsyncLatch()
        let waiterEntered = AsyncLatch()

        let holderTask = Task {
            try await holder.withExclusiveLaunch {
                await holderEntered.signal()
                await releaseHolder.wait()
            }
        }
        await holderEntered.wait()

        let originalLockMetadata = try metadata(
            at: harness.lockFileURL
        )
        let waiterTask = Task {
            await waiterAttempted.signal()
            try await waiter.withExclusiveLaunch {
                await waiterEntered.signal()
            }
        }
        await waiterAttempted.wait()

        let waiterOpenedOriginalDirectoryLock =
            await waitForOpenDescriptorCount(
                matching: originalLockMetadata,
                atLeast: 2
            )
        XCTAssertTrue(
            waiterOpenedOriginalDirectoryLock,
            "waiter가 기존 directory의 lock inode를 연 상태여야 합니다"
        )

        let movedDirectoryURL = harness.rootURL
            .appendingPathComponent(
                "Antigravity-moved",
                isDirectory: true
            )
        try FileManager.default.moveItem(
            at: harness.directoryURL,
            to: movedDirectoryURL
        )
        try FileManager.default.createDirectory(
            at: harness.directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        await releaseHolder.signal()
        try await holderTask.value

        do {
            try await waiterTask.value
            XCTFail("교체된 directory pathname으로 임계구간에 진입하면 안 됩니다")
        } catch let error as AntigravityManagedLaunchCoordinatorError {
            XCTAssertEqual(error, .invalidDirectory)
        }
        let enteredReplacedDirectory =
            await waiterEntered.isSignaled
        XCTAssertFalse(enteredReplacedDirectory)
    }

    private func waitForOpenDescriptorCount(
        matching expected: stat,
        atLeast expectedCount: Int
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(
            by: .seconds(2)
        )
        while ContinuousClock.now < deadline {
            if openDescriptorCount(matching: expected)
                >= expectedCount {
                return true
            }
            try? await Task<Never, Never>.sleep(
                for: .milliseconds(5)
            )
        }
        return false
    }

    private func openDescriptorCount(
        matching expected: stat
    ) -> Int {
        var count = 0
        for descriptor in 0..<getdtablesize() {
            var current = stat()
            guard fstat(descriptor, &current) == 0 else {
                continue
            }
            if current.st_dev == expected.st_dev,
               current.st_ino == expected.st_ino {
                count += 1
            }
        }
        return count
    }

    private func metadata(at url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return value
    }

    private func posixPermissions(_ mode: mode_t) -> Int {
        Int(mode & mode_t(0o7777))
    }
}

private enum ExpectedLaunchFailure: Error, Equatable {
    case failed
}

private actor AsyncLatch {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isSignaled: Bool {
        signaled
    }

    func wait() async {
        if signaled {
            return
        }
        await withCheckedContinuation { continuation in
            if signaled {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func signal() {
        guard !signaled else { return }
        signaled = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private actor CriticalSectionProbe {
    private(set) var activeCount = 0
    private(set) var maximumActiveCount = 0

    func enter() {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
    }

    func leave() {
        activeCount -= 1
    }
}

private final class LaunchCoordinatorHarness {
    let rootURL: URL
    let directoryURL: URL
    let lockFileURL: URL

    init(createDirectory: Bool = false) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ClaudeUsageManagedLaunchCoordinatorTests-\(UUID().uuidString)",
                isDirectory: true
            )
        directoryURL = rootURL.appendingPathComponent(
            "Antigravity",
            isDirectory: true
        )
        lockFileURL = directoryURL.appendingPathComponent(
            AntigravityManagedLaunchFileCoordinator.lockFileName
        )
        if createDirectory {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    func makeCoordinator(
        expectedUserID: uid_t = geteuid()
    ) -> AntigravityManagedLaunchFileCoordinator {
        AntigravityManagedLaunchFileCoordinator(
            directoryURL: directoryURL,
            expectedUserID: expectedUserID,
            retryDelayNanoseconds: 1_000_000
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
